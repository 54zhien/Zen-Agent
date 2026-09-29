import Foundation
import GRDB

struct ConversationInitialBinding: Equatable, Sendable {
    let providerInstanceID: ProviderInstanceID?
    let modelID: ModelID?
    init(providerInstanceID: ProviderInstanceID? = nil, modelID: ModelID? = nil) {
        self.providerInstanceID = providerInstanceID
        self.modelID = modelID
    }
}

extension PersistenceStore {
    func createEmptyConversation(id: String, at now: Date, initialBinding: ConversationInitialBinding = .init()) throws {
        guard !id.isEmpty, now.timeIntervalSince1970.isFinite else { throw PersistenceError.invalidTransition("Invalid empty conversation") }
        try validateInitialBinding(initialBinding)
        try database.write { db in
            try ConversationRecord(id: id, title: "", createdAt: now, updatedAt: now,
                userActiveAt: now, pinned: false, lifecycle: .visible).insert(db)
            try db.execute(sql: "INSERT INTO conversationInitialBinding(conversationID, providerInstanceID, modelID) VALUES (?, ?, ?)",
                arguments: [id, initialBinding.providerInstanceID?.rawValue, initialBinding.modelID?.rawValue])
            if let soul = try SoulRecord.fetchOne(db, key: SoulRecord.globalID), soul.enabled {
                try ConversationSoulBindingRecord(conversationID: id,
                    soulVersionID: soul.currentVersionID, createdAt: now).insert(db)
            }
        }
    }
    func conversationInitialBinding(id: String) throws -> ConversationInitialBinding? {
        try database.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT providerInstanceID, modelID FROM conversationInitialBinding WHERE conversationID = ?", arguments: [id]) else { return nil }
            let instance: String? = row["providerInstanceID"]
            let model: String? = row["modelID"]
            return ConversationInitialBinding(providerInstanceID: instance.map { ProviderInstanceID(rawValue: $0) },
                modelID: model.map { ModelID(rawValue: $0) })
        }
    }
    func initializeEmptyConversationBinding(id: String, binding: ConversationInitialBinding, at now: Date) throws -> Bool {
        try validateInitialBinding(binding)
        guard binding.providerInstanceID != nil, now.timeIntervalSince1970.isFinite else { return false }
        return try database.write { db in
            try requireEditableConversation(id: id, in: db)
            guard try MessageRecord.filter(Column("conversationID") == id).fetchCount(db) == 0,
                  try AgentRunRecord.filter(Column("conversationID") == id).fetchCount(db) == 0 else { return false }
            try db.execute(sql: """
                UPDATE conversationInitialBinding SET providerInstanceID = ?, modelID = ?
                WHERE conversationID = ? AND providerInstanceID IS NULL AND modelID IS NULL
                """, arguments: [binding.providerInstanceID?.rawValue, binding.modelID?.rawValue, id])
            guard db.changesCount == 1 else { return false }
            try db.execute(sql: "UPDATE conversation SET updatedAt = MAX(updatedAt, ?) WHERE id = ?", arguments: [now, id])
            return true
        }
    }
    func renameConversation(id: String, title: String, at now: Date) throws {
        let normalized = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !normalized.isEmpty, normalized.count <= 512, now.timeIntervalSince1970.isFinite else {
            throw PersistenceError.invalidTransition("Invalid conversation title")
        }
        try database.write { db in
            try requireEditableConversation(id: id, in: db)
            try db.execute(sql: "UPDATE conversation SET title = ?, updatedAt = MAX(updatedAt, ?) WHERE id = ?",
                arguments: [normalized, now, id])
            try db.execute(sql: "INSERT OR IGNORE INTO conversationManualTitle(conversationID) VALUES (?)", arguments: [id])
        }
    }

    func setConversationPinned(id: String, pinned: Bool, at now: Date) throws {
        guard now.timeIntervalSince1970.isFinite else { throw PersistenceError.invalidTransition("Invalid metadata date") }
        try database.write { db in
            try requireEditableConversation(id: id, in: db)
            // Never save a stale whole-record snapshot or manufacture activity for Pin.
            try db.execute(sql: "UPDATE conversation SET pinned = ?, updatedAt = MAX(updatedAt, ?) WHERE id = ?",
                arguments: [pinned, now, id])
        }
    }

    func hasManualConversationTitle(id: String) throws -> Bool {
        try database.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM conversationManualTitle WHERE conversationID = ?)", arguments: [id]) ?? false
        }
    }

    private func requireEditableConversation(id: String, in db: Database) throws {
        guard let row = try ConversationRecord.fetchOne(db, key: id) else { throw PersistenceError.conversationNotFound(id) }
        guard row.lifecycle == .visible else { throw PersistenceError.invalidTransition("Conversation is not visible") }
    }
    private func validateInitialBinding(_ binding: ConversationInitialBinding) throws {
        guard (binding.providerInstanceID == nil) == (binding.modelID == nil),
              binding.providerInstanceID?.rawValue.isEmpty != true, binding.modelID?.rawValue.isEmpty != true else {
            throw PersistenceError.invalidTransition("Invalid initial model binding")
        }
    }
}

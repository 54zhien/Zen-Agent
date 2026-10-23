import Foundation
import GRDB

extension PersistenceStore {
    var memoryAccessGate: MemoryAccessGate { database.memoryAccessGate }

    func resolveMemoryReferences(_ references: [MemoryRevisionReference]) throws -> [MemoryContext] {
        try database.read { db in try Self.resolveMemoryReferences(references, db: db) }
    }

    static func resolveMemoryReferences(_ references: [MemoryRevisionReference], db: Database) throws -> [MemoryContext] {
        guard references.count <= 6 else { throw MemoryError.erasedDependency }
        var bytes = 0
        return try references.map { reference in
            guard let revision = try MemoryRevisionRecord.fetchOne(db, key: reference.revisionID),
                  revision.memoryID.utf8.elementsEqual(reference.memoryID.utf8),
                  try MemoryRecord.fetchOne(db, key: reference.memoryID) != nil,
                  revision.content.utf8.count <= MemoryContentPolicy.maximumUTF8Bytes else { throw MemoryError.erasedDependency }
            bytes += revision.content.utf8.count
            guard bytes <= MemoryRetriever.maximumCombinedUTF8Bytes else { throw MemoryError.erasedDependency }
            return MemoryContext(reference: reference, content: revision.content)
        }
    }

    func invalidateMemoryRun(id: String) throws {
        try database.write { try $0.execute(sql: "UPDATE agentRun SET recoveryAction = 'invalidate' WHERE id = ? AND state NOT IN ('completed','failed','cancelled')", arguments: [id]) }
    }

    func memorySettings() throws -> MemorySettings {
        try database.read { try Self.memorySettings($0) }
    }

    static func memorySettings(_ db: Database) throws -> MemorySettings {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM memorySettings WHERE id = 'global'")
        else { throw MemoryError.validationUnavailable }
        return MemorySettings(enabled: row["enabled"], automaticEnabled: row["automaticEnabled"], generation: row["generation"])
    }

    func setMemoryEnabled(_ enabled: Bool) throws {
        try database.write { try $0.execute(sql: "UPDATE memorySettings SET enabled = ?, generation = generation + 1 WHERE id = 'global'", arguments: [enabled]) }
    }

    func setMemoryAutomatic(_ enabled: Bool) throws {
        try database.write { try $0.execute(sql: "UPDATE memorySettings SET automaticEnabled = ?, generation = generation + 1 WHERE id = 'global'", arguments: [enabled]) }
    }

    func memories(activeOnly: Bool = false) throws -> [MemoryItem] {
        try database.read { db in
            let records = try MemoryRecord.fetchAll(db, sql: "SELECT * FROM memoryRecord \(activeOnly ? "WHERE state = 'active'" : "") ORDER BY updatedAt DESC, id")
            return try records.map { try Self.memoryItem($0, db: db) }
        }
    }

    func memoryRevision(id: String) throws -> MemoryRevisionRecord? {
        try database.read { try MemoryRevisionRecord.fetchOne($0, key: id) }
    }

    @discardableResult
    func saveMemory(id: String? = nil, expectedRevisionID: String? = nil, content: String,
                    origin: MemoryOrigin = .manual, factKey: String? = nil, source: MemorySource? = nil,
                    at now: Date = Date()) throws -> MemoryItem {
        guard MemoryContentPolicy.allows(content) else { throw MemoryError.unsafeContent }
        return try database.write { db in
            try Self.saveMemory(db, id: id, expectedRevisionID: expectedRevisionID, content: content,
                origin: origin, factKey: factKey, source: source, at: now)
        }
    }

    static func saveMemory(_ db: Database, id: String?, expectedRevisionID: String?, content: String,
                           origin: MemoryOrigin, factKey: String?, source: MemorySource?, at now: Date) throws -> MemoryItem {
        let revisionID = UUID().uuidString
        var record: MemoryRecord
        if let id {
            guard var current = try MemoryRecord.fetchOne(db, key: id) else { throw MemoryError.notFound }
            guard current.currentRevisionID == expectedRevisionID else { throw MemoryError.editConflict }
            current.currentRevisionID = revisionID; current.updatedAt = now
            current.origin = origin == .manual ? .userEdited : origin
            current.factKey = factKey ?? current.factKey
            record = current
            try current.update(db)
        } else {
            record = MemoryRecord(id: UUID().uuidString, currentRevisionID: revisionID, state: "active",
                origin: origin, factKey: factKey, createdAt: now, updatedAt: now)
            try record.insert(db)
        }
        try MemoryRevisionRecord(id: revisionID, memoryID: record.id, content: content, createdAt: now).insert(db)
        if let source { try addMemorySource(source, memoryID: record.id, db: db, at: now) }
        return try memoryItem(record, db: db)
    }

    static func addMemorySource(_ source: MemorySource, memoryID: String, db: Database, at now: Date) throws {
        let existing = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM memorySource WHERE memoryID = ? AND conversationID IS ? AND messageID IS ? AND kind = ?)",
            arguments: [memoryID, source.conversationID, source.messageID, source.kind.rawValue]) ?? false
        guard !existing else { return }
        let finalized = try source.conversationID.map {
            try String.fetchOne(db, sql: "SELECT lifecycle FROM conversation WHERE id = ?", arguments: [$0]) == ConversationLifecycle.finalizedDeletion.rawValue
        } ?? false
        try MemorySourceRecord(id: source.id, memoryID: memoryID, conversationID: source.conversationID,
            messageID: source.messageID, kind: source.kind, missing: source.missing || finalized, createdAt: now).insert(db)
    }

    static func memoryItem(_ record: MemoryRecord, db: Database) throws -> MemoryItem {
        guard let revision = try MemoryRevisionRecord.fetchOne(db, key: record.currentRevisionID), revision.memoryID == record.id
        else { throw MemoryError.erasedDependency }
        let sources = try MemorySourceRecord.fetchAll(db, sql: "SELECT * FROM memorySource WHERE memoryID = ? ORDER BY createdAt, id", arguments: [record.id]).map { record in
            var source = record.source
            if !source.missing, let id = source.conversationID {
                source.conversationTitle = try ConversationRecord.fetchOne(db, key: id)?.title
            }
            return source
        }
        return MemoryItem(id: record.id, revisionID: revision.id, content: revision.content, origin: record.origin,
            factKey: record.factKey, archived: record.state == "archived", createdAt: record.createdAt,
            updatedAt: record.updatedAt, sources: sources)
    }

    func deleteMemory(id: String) throws {
        try database.write { db in
            try Self.invalidateMemoryRuns(db, ids: [id])
            try db.execute(sql: "DELETE FROM memoryRecord WHERE id = ?", arguments: [id])
            try db.execute(sql: "UPDATE memorySettings SET generation = generation + 1 WHERE id = 'global'")
        }
    }

    func clearMemory() throws {
        try database.write { db in
            let ids = try String.fetchAll(db, sql: "SELECT id FROM memoryRecord")
            try Self.invalidateMemoryRuns(db, ids: ids)
            try db.execute(sql: "DELETE FROM memoryRecord")
            try db.execute(sql: "UPDATE memorySettings SET generation = generation + 1 WHERE id = 'global'")
        }
    }

    private static func invalidateMemoryRuns(_ db: Database, ids: [String]) throws {
        for id in ids {
            // Malformed legacy snapshots cannot prevent erasure. They already fail
            // closed in recovery. Valid snapshots retain only content-free refs.
            try db.execute(sql: """
                UPDATE agentRun SET recoveryAction = 'invalidate'
                WHERE state NOT IN ('completed','failed','cancelled') AND id IN (
                    SELECT r.id FROM agentRun r,
                    json_each(CASE WHEN json_valid(r.executionSnapshot) THEN r.executionSnapshot ELSE '{}' END,
                              '$.prompt.memoryReferences') AS m
                    WHERE CASE WHEN m.type = 'object' THEN json_extract(m.value, '$.memoryID') ELSE NULL END = ?
                )
                """, arguments: [id])
        }
    }
}

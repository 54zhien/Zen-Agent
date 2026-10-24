import Foundation
import GRDB

extension PersistenceStore {
    func validateExtensionDependencies(runID: String, snapshot: RunExecutionSnapshot) throws {
        try database.read { try Self.validateExtensionDependencies(runID: runID, snapshot: snapshot, db: $0) }
    }

    static func validateExtensionDependencies(runID: String, snapshot: RunExecutionSnapshot, db: Database) throws {
        let json = try db.tableExists("runSkillSelection")
            ? String.fetchOne(db, sql: "SELECT selectionJSON FROM runSkillSelection WHERE runID = ?", arguments: [runID]) : nil
        let committed = try json.map { try JSONDecoder().decode([SkillActivationReference].self, from: Data($0.utf8)) } ?? []
        guard committed == snapshot.prompt.skillReferences else { throw SkillError.erasedDependency }
        let items = try Self.resolveSkillItems(committed, db: db)
        guard items.allSatisfy({ item in item.definition.requiredTools.allSatisfy { required in
            snapshot.exposedTools.contains { $0.toolID == required }
        } }) else { throw SkillError.erasedDependency }
    }

    func seedSkillCatalog() throws {
        try database.write { db in
            for item in SkillCatalog.items {
                let encoded = String(decoding: try JSONEncoder().encode(item.definition), as: UTF8.self)
                if let record = try SkillRecord.fetchOne(db, key: item.id) {
                    guard record.source == .builtIn else { throw SkillError.erasedDependency }
                    if let version = try SkillRevisionRecord.fetchOne(db, key: item.revisionID) {
                        guard try version.decodedDefinition == item.definition else { throw SkillError.erasedDependency }
                    } else {
                        try SkillRevisionRecord(id: item.revisionID, skillID: item.id, definition: encoded, createdAt: Date()).insert(db)
                        try db.execute(sql: "UPDATE skillRecord SET currentRevisionID = ? WHERE id = ?", arguments: [item.revisionID, item.id])
                    }
                } else {
                    try SkillRecord(id: item.id, source: .builtIn, enabled: false, currentRevisionID: item.revisionID,
                        state: "active", createdAt: Date(), updatedAt: Date()).insert(db)
                    try SkillRevisionRecord(id: item.revisionID, skillID: item.id, definition: encoded, createdAt: Date()).insert(db)
                }
            }
        }
    }

    func skills() throws -> [SkillItem] {
        try database.read { db in
            try SkillRecord.fetchAll(db, sql: "SELECT * FROM skillRecord ORDER BY source,id").map { try Self.skillItem($0, db: db) }
        }
    }

    static func skillItem(_ record: SkillRecord, revisionID: String? = nil, db: Database) throws -> SkillItem {
        guard let revision = try SkillRevisionRecord.fetchOne(db, key: revisionID ?? record.currentRevisionID), revision.skillID == record.id
        else { throw SkillError.erasedDependency }
        return .init(id: record.id, revisionID: revision.id, source: record.source, definition: try revision.decodedDefinition,
            enabled: record.enabled, pendingDeletion: record.state == "deleting")
    }

    func saveUserSkill(id: String?, expectedRevisionID: String?, definition: SkillDefinition) throws -> SkillItem {
        guard SkillValidation.allows(definition) else { throw SkillError.invalidDefinition }
        let encoded = String(decoding: try JSONEncoder().encode(definition), as: UTF8.self)
        return try database.write { db in
            let versionID = UUID().uuidString
            var record: SkillRecord
            if let id {
                guard var existing = try SkillRecord.fetchOne(db, key: id), existing.state == "active" else { throw SkillError.notFound }
                guard existing.source == .userCreated else { throw SkillError.builtInReadOnly }
                guard existing.currentRevisionID == expectedRevisionID else { throw SkillError.editConflict }
                existing.currentRevisionID = versionID; existing.updatedAt = Date()
                try existing.update(db); record = existing
            } else {
                record = .init(id: "user-\(UUID().uuidString)", source: .userCreated, enabled: false,
                    currentRevisionID: versionID, state: "active", createdAt: Date(), updatedAt: Date())
                try record.insert(db)
            }
            try SkillRevisionRecord(id: versionID, skillID: record.id, definition: encoded, createdAt: Date()).insert(db)
            return try Self.skillItem(record, db: db)
        }
    }

    func resolveSkillItems(_ references: [SkillActivationReference]) throws -> [SkillItem] {
        try database.read { try Self.resolveSkillItems(references, db: $0) }
    }

    static func resolveSkillItems(_ references: [SkillActivationReference], db: Database, requireCurrent: Bool = false) throws -> [SkillItem] {
        guard SkillActivationReference.areWellFormed(references) else { throw SkillError.erasedDependency }
        return try references.map { reference in
            guard let record = try SkillRecord.fetchOne(db, key: reference.skillID), record.enabled, record.state == "active",
                  !requireCurrent || record.currentRevisionID == reference.revisionID else { throw SkillError.erasedDependency }
            let item = try Self.skillItem(record, revisionID: reference.revisionID, db: db)
            let variables = try Self.resolveEnvironmentReferences(reference.environmentReferences, db: db)
            if requireCurrent {
                let selected = try EnvironmentResolution.select(skillID: item.id, declaredKeys: item.definition.environmentKeys,
                    available: Self.environmentItems(db: db))
                guard Set(selected.map(\.reference)) == Set(reference.environmentReferences) else { throw SkillError.editConflict }
            }
            guard variables.allSatisfy({ $0.scope == .global || $0.scope == .skill(item.id) }),
                  Set(variables.map(\.key)) == Set(item.definition.environmentKeys),
                  Set(variables.map(\.key)).count == variables.count,
                  EnvironmentBindingIdentity.fingerprint(skillID: item.id, keys: item.definition.environmentKeys,
                    references: reference.environmentReferences) == reference.environmentFingerprint
            else { throw SkillError.erasedDependency }
            for variable in variables {
                if requireCurrent {
                    guard let current = try EnvironmentVariableRecord.fetchOne(db, key: variable.id),
                          current.currentRevisionID == variable.revisionID else { throw SkillError.editConflict }
                }
                if case .secret(let binding) = variable.value {
                    guard let metadata = try CredentialMetadataRecord.fetchOne(db, sql:
                        "SELECT * FROM credentialBinding WHERE credentialID = ? AND kind = ?", arguments: [binding.reference.id, binding.reference.kind.rawValue]),
                          metadata.status == "active", metadata.bindingGeneration == binding.generation else { throw SkillError.erasedDependency }
                }
            }
            return item
        }
    }

    func runSkillReferences(runID: String) throws -> [SkillActivationReference] {
        try database.read { db in
            guard try db.tableExists("runSkillSelection"),
                  let json = try String.fetchOne(db, sql: "SELECT selectionJSON FROM runSkillSelection WHERE runID = ?", arguments: [runID]) else { return [] }
            let references = try JSONDecoder().decode([SkillActivationReference].self, from: Data(json.utf8))
            guard SkillActivationReference.areWellFormed(references) else { throw SkillError.erasedDependency }
            return references
        }
    }

    static func commitSkillSelection(_ references: [SkillActivationReference], runID: String, db: Database) throws {
        guard !references.isEmpty else { return }
        _ = try Self.resolveSkillItems(references, db: db, requireCurrent: true)
        let json = String(decoding: try JSONEncoder().encode(references), as: UTF8.self)
        try db.execute(sql: "INSERT INTO runSkillSelection(runID,selectionJSON) VALUES (?,?)", arguments: [runID, json])
    }

    func skillDependentRunIDs(id: String) throws -> [String] { try database.read { try Self.skillDependentRunIDs(id: id, db: $0) } }

    static func skillDependentRunIDs(id: String, db: Database) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT r.id FROM agentRun r WHERE r.state NOT IN ('completed','failed','cancelled') AND (
                EXISTS (SELECT 1 FROM json_tree(CASE WHEN json_valid(r.executionSnapshot) THEN r.executionSnapshot ELSE '{}' END) j WHERE j.key = 'skillID' AND j.value = ?)
                OR EXISTS (SELECT 1 FROM runSkillSelection s, json_tree(s.selectionJSON) j WHERE s.runID = r.id AND j.key = 'skillID' AND j.value = ?)
            ) ORDER BY r.id
            """, arguments: [id, id])
    }

    func revokeSkill(id: String, deleting: Bool) throws -> [String] {
        try database.write { db in
            guard let record = try SkillRecord.fetchOne(db, key: id) else { throw SkillError.notFound }
            if deleting, record.source == .builtIn { throw SkillError.builtInReadOnly }
            try db.execute(sql: "UPDATE skillRecord SET enabled = 0, state = ?, updatedAt = ? WHERE id = ?",
                arguments: [deleting ? "deleting" : record.state, Date(), id])
            let runs = try Self.skillDependentRunIDs(id: id, db: db)
            for run in runs { try db.execute(sql: "UPDATE agentRun SET recoveryAction = 'invalidate' WHERE id = ?", arguments: [run]) }
            return runs
        }
    }

    func enableSkill(id: String) throws {
        try database.write { db in
            guard let record = try SkillRecord.fetchOne(db, key: id), record.state == "active" else { throw SkillError.notFound }
            try db.execute(sql: "UPDATE skillRecord SET enabled = 1, updatedAt = ? WHERE id = ?", arguments: [Date(), id])
        }
    }

    func finishSkillDeletion(id: String) throws {
        try database.write { db in
            let scopedVariables = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM environmentVariable WHERE scope = ?)", arguments: ["skill:\(id)"]) ?? true
            guard try Self.skillDependentRunIDs(id: id, db: db).isEmpty,
                  !scopedVariables else { throw SkillError.resourceInUse }
            try db.execute(sql: "DELETE FROM skillRecord WHERE id = ? AND source = 'userCreated' AND state = 'deleting'", arguments: [id])
        }
    }
}

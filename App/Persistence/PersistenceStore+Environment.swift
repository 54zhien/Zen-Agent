import Foundation
import GRDB

extension PersistenceStore {
    func environmentVariables() throws -> [EnvironmentItem] {
        try database.read { db in
            try Self.environmentItems(db: db)
        }
    }

    static func environmentItems(db: Database) throws -> [EnvironmentItem] {
        try EnvironmentVariableRecord.fetchAll(db, sql: "SELECT * FROM environmentVariable ORDER BY scope,key,id")
            .map { try Self.environmentItem($0, db: db) }
    }

    func environmentScopeExists(_ scope: EnvironmentScope) throws -> Bool {
        try database.read { try Self.environmentScopeExists(scope, db: $0) }
    }

    static func environmentScopeExists(_ scope: EnvironmentScope, db: Database) throws -> Bool {
        guard let id = scope.skillID else { return true }
        guard !id.isEmpty, id.utf8.count <= 128, try db.tableExists("skillRecord") else { return false }
        return try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM skillRecord WHERE id = ? AND state = 'active')", arguments: [id]) ?? false
    }

    func saveEnvironmentValue(id: String?, expectedRevisionID: String?, scope: EnvironmentScope,
                              key: String, value: EnvironmentStoredValue,
                              clearingCredentialRetirement bindingToClear: CredentialBindingSnapshot? = nil,
                              at now: Date = Date()) throws -> EnvironmentItem {
        guard EnvironmentValidation.allowsKey(key) else { throw EnvironmentError.invalidKey }
        if case .plain(let plain) = value, !EnvironmentValidation.allowsPlain(plain) { throw EnvironmentError.invalidValue }
        if let bindingToClear {
            guard bindingToClear.reference.kind == .environmentSecret,
                  bindingToClear.generation > 0,
                  case .secret(let storedBinding) = value,
                  storedBinding == bindingToClear else { throw EnvironmentError.invalidValue }
        }
        return try database.write { db in
            guard try Self.environmentScopeExists(scope, db: db) else { throw EnvironmentError.invalidScope }
            let revisionID = UUID().uuidString
            var variable: EnvironmentVariableRecord
            if let id {
                guard var current = try EnvironmentVariableRecord.fetchOne(db, key: id), current.state == "active" else { throw EnvironmentError.notFound }
                guard current.currentRevisionID == expectedRevisionID else { throw EnvironmentError.editConflict }
                // Keys and scopes are identities, not mutable aliases for a frozen reference.
                guard current.scope == scope.storageID, current.key == key else { throw EnvironmentError.invalidScope }
                current.currentRevisionID = revisionID; current.updatedAt = now
                try current.update(db)
                variable = current
            } else {
                guard try EnvironmentVariableRecord.fetchOne(db, sql: "SELECT * FROM environmentVariable WHERE scope = ? AND key = ?", arguments: [scope.storageID, key]) == nil else { throw EnvironmentError.duplicateKey }
                variable = .init(id: UUID().uuidString, scope: scope.storageID, key: key,
                    currentRevisionID: revisionID, state: "active", createdAt: now, updatedAt: now)
                try variable.insert(db)
            }
            let revision: EnvironmentRevisionRecord
            switch value {
            case .plain(let plain):
                revision = .init(id: revisionID, variableID: variable.id, kind: "plain", plainValue: plain,
                    credentialReferenceID: nil, credentialKind: nil, credentialGeneration: nil, createdAt: now)
            case .secret(let binding):
                guard binding.reference.kind == .environmentSecret, binding.generation > 0 else { throw EnvironmentError.invalidValue }
                revision = .init(id: revisionID, variableID: variable.id, kind: "secret", plainValue: nil,
                    credentialReferenceID: binding.reference.id, credentialKind: binding.reference.kind.rawValue,
                    credentialGeneration: binding.generation, createdAt: now)
            }
            try revision.insert(db)
            if let bindingToClear {
                try Self.completeCredentialRetirement(bindingToClear, db: db)
            }
            return try Self.environmentItem(variable, revision: revision, db: db)
        }
    }

    func resolveEnvironmentReferences(_ references: [EnvironmentRevisionReference]) throws -> [EnvironmentItem] {
        try database.read { try Self.resolveEnvironmentReferences(references, db: $0) }
    }

    static func resolveEnvironmentReferences(_ references: [EnvironmentRevisionReference], db: Database) throws -> [EnvironmentItem] {
        guard references.count <= 64, Set(references).count == references.count else { throw EnvironmentError.erasedDependency }
        return try references.map { reference in
                guard let record = try EnvironmentVariableRecord.fetchOne(db, key: reference.variableID), record.state == "active",
                      let revision = try EnvironmentRevisionRecord.fetchOne(db, key: reference.revisionID), revision.variableID == record.id
                else { throw EnvironmentError.erasedDependency }
                return try Self.environmentItem(record, revision: revision, db: db)
        }
    }

    private static func environmentItem(_ record: EnvironmentVariableRecord, revision supplied: EnvironmentRevisionRecord? = nil,
                                        db: Database) throws -> EnvironmentItem {
        guard let revision = try supplied ?? EnvironmentRevisionRecord.fetchOne(db, key: record.currentRevisionID), revision.variableID == record.id else { throw EnvironmentError.erasedDependency }
        let scope: EnvironmentScope
        if record.scope == "global" { scope = .global }
        else if record.scope.hasPrefix("skill:"), record.scope.count > 6 { scope = .skill(String(record.scope.dropFirst(6))) }
        else { throw EnvironmentError.erasedDependency }
        return EnvironmentItem(id: record.id, revisionID: revision.id, scope: scope, key: record.key,
            value: try revision.storedValue, updatedAt: record.updatedAt, pendingDeletion: record.state == "deleting")
    }

    func environmentCredentialBindings() throws -> [CredentialBindingSnapshot] {
        try database.read { db in
            try EnvironmentRevisionRecord.fetchAll(db, sql: "SELECT * FROM environmentRevision WHERE kind = 'secret'").map {
                guard case .secret(let binding) = try $0.storedValue else { throw EnvironmentError.erasedDependency }
                return binding
            }
        }
    }

    func environmentDependentRunIDs(id: String) throws -> [String] {
        try database.read { try Self.environmentDependentRunIDs(id: id, db: $0) }
    }

    private static func environmentDependentRunIDs(id: String, db: Database) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT r.id FROM agentRun r WHERE r.state NOT IN ('completed','failed','cancelled') AND (
                EXISTS (SELECT 1 FROM json_tree(CASE WHEN json_valid(r.executionSnapshot) THEN r.executionSnapshot ELSE '{}' END) j WHERE j.key = 'variableID' AND j.value = ?)
                OR EXISTS (SELECT 1 FROM runSkillSelection s, json_tree(s.selectionJSON) j WHERE s.runID = r.id AND j.key = 'variableID' AND j.value = ?)
            ) ORDER BY r.id
            """, arguments: [id, id])
    }

    func beginEnvironmentDeletion(id: String) throws -> [String] {
        try database.write { db in
            guard try EnvironmentVariableRecord.fetchOne(db, key: id) != nil else { throw EnvironmentError.notFound }
            try db.execute(sql: "UPDATE environmentVariable SET state = 'deleting' WHERE id = ?", arguments: [id])
            let runs = try Self.environmentDependentRunIDs(id: id, db: db)
            for run in runs { try db.execute(sql: "UPDATE agentRun SET recoveryAction = 'invalidate' WHERE id = ?", arguments: [run]) }
            return runs
        }
    }

    func finishEnvironmentDeletion(id: String) throws {
        try database.write { db in
            guard try Self.environmentDependentRunIDs(id: id, db: db).isEmpty else { throw EnvironmentError.resourceInUse }
            let revisions = try EnvironmentRevisionRecord.fetchAll(db, sql: "SELECT * FROM environmentRevision WHERE variableID = ? AND kind = 'secret'", arguments: [id])
            try db.execute(sql: "DELETE FROM environmentVariable WHERE id = ? AND state = 'deleting'", arguments: [id])
            for revision in revisions {
                guard case .secret(let binding) = try revision.storedValue else { continue }
                if try !Self.credentialIsReferenced(binding.reference, db: db) {
                    try Self.queueCredentialRetirement(binding, db: db)
                }
            }
        }
    }

    private static func credentialIsReferenced(_ reference: CredentialReference, db: Database) throws -> Bool {
        try (Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM environmentRevision WHERE credentialReferenceID = ? AND credentialKind = ?) OR EXISTS(SELECT 1 FROM providerInstance WHERE credentialID = ? AND credentialKind = ?)", arguments: [reference.id, reference.kind.rawValue, reference.id, reference.kind.rawValue]) ?? false)
    }

    func environmentCredentialIsReferenced(_ reference: CredentialReference) throws -> Bool {
        try database.read { try Self.credentialIsReferenced(reference, db: $0) }
    }

    private static func queueCredentialRetirement(_ binding: CredentialBindingSnapshot, db: Database) throws {
        try db.execute(sql: "INSERT OR IGNORE INTO extensionCredentialRetirement(referenceID,kind,generation,createdAt) VALUES (?,?,?,?)",
            arguments: [binding.reference.id, binding.reference.kind.rawValue, binding.generation, Date()])
    }

    private static func completeCredentialRetirement(_ binding: CredentialBindingSnapshot, db: Database) throws {
        try db.execute(sql: "DELETE FROM extensionCredentialRetirement WHERE referenceID = ? AND kind = ? AND generation = ?",
            arguments: [binding.reference.id, binding.reference.kind.rawValue, binding.generation])
    }

    func queueEnvironmentCredentialRetirement(_ binding: CredentialBindingSnapshot) throws {
        try database.write { db in
            guard try !Self.credentialIsReferenced(binding.reference, db: db) else {
                throw EnvironmentError.erasedDependency
            }
            try Self.queueCredentialRetirement(binding, db: db)
        }
    }

    func pendingEnvironmentCredentialRetirements() throws -> [CredentialBindingSnapshot] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM extensionCredentialRetirement ORDER BY referenceID").map { row in
                guard let kind = CredentialKind(rawValue: row["kind"]) else { throw EnvironmentError.validationUnavailable }
                return .init(reference: .init(id: row["referenceID"], kind: kind), generation: row["generation"])
            }
        }
    }

    func queueUnattachedEnvironmentCredentials() throws {
        try database.write { db in
            let records = try CredentialMetadataRecord.fetchAll(db, sql:
                "SELECT * FROM credentialBinding WHERE kind = 'environmentSecret' AND status = 'active'")
            for record in records {
                let reference = CredentialReference(id: record.credentialID, kind: .environmentSecret)
                if try !Self.credentialIsReferenced(reference, db: db) {
                    try Self.queueCredentialRetirement(.init(reference: reference, generation: record.bindingGeneration), db: db)
                }
            }
        }
    }

    func completeEnvironmentCredentialRetirement(_ binding: CredentialBindingSnapshot) throws {
        try database.write { try Self.completeCredentialRetirement(binding, db: $0) }
    }
}

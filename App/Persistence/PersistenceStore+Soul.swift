import Foundation
import GRDB

extension PersistenceStore {
    func createSoul(initialVersion: SoulVersionRecord, at now: Date) throws {
        do {
            try database.write { db in
                guard try SoulRecord.fetchOne(db, key: SoulRecord.globalID) == nil else {
                    throw PersistenceError.soulAlreadyExists
                }
                try initialVersion.insert(db)
                try SoulRecord(
                    id: SoulRecord.globalID,
                    currentVersionID: initialVersion.id,
                    updatedAt: now,
                    enabled: true
                ).insert(db)
            }
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
            throw PersistenceError.constraintViolation
        }
    }

    func advanceSoul(
        expectedCurrentVersionID: String,
        to version: SoulVersionRecord,
        at now: Date
    ) throws {
        do {
            try database.write { db in
                guard let current = try SoulRecord.fetchOne(db, key: SoulRecord.globalID) else {
                    throw PersistenceError.soulNotFound
                }
                guard current.currentVersionID == expectedCurrentVersionID else {
                    throw PersistenceError.soulEditConflict(
                        expected: expectedCurrentVersionID,
                        actual: current.currentVersionID
                    )
                }

                try version.insert(db)
                try db.execute(
                    sql: "UPDATE soul SET currentVersionID = ?, updatedAt = ? WHERE id = ?",
                    arguments: [version.id, now, SoulRecord.globalID]
                )
            }
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
            throw PersistenceError.constraintViolation
        }
    }

    func currentSoulVersion() throws -> SoulVersionRecord? {
        try database.read { db in
            guard let soul = try SoulRecord.fetchOne(db, key: SoulRecord.globalID) else {
                return nil
            }
            return try SoulVersionRecord.fetchOne(db, key: soul.currentVersionID)
        }
    }

    func soul() throws -> SoulRecord? {
        try database.read { db in
            try SoulRecord.fetchOne(db, key: SoulRecord.globalID)
        }
    }

    func setSoulEnabled(_ enabled: Bool, at now: Date) throws {
        try database.write { db in
            guard try SoulRecord.fetchOne(db, key: SoulRecord.globalID) != nil else {
                throw PersistenceError.soulNotFound
            }
            try db.execute(
                sql: "UPDATE soul SET enabled = ?, updatedAt = ? WHERE id = ?",
                arguments: [enabled, now, SoulRecord.globalID]
            )
        }
    }

    func boundSoulVersion(conversationID: String) throws -> SoulVersionRecord? {
        try database.read { db in
            guard let binding = try ConversationSoulBindingRecord.fetchOne(
                db, key: conversationID
            ) else {
                return nil
            }
            return try SoulVersionRecord.fetchOne(db, key: binding.soulVersionID)
        }
    }

    /// Resolves the exact version a Conversation may use with the global Soul setting.
    /// The enabled flag, immutable binding and version text share one SQL read so a
    /// run cannot snapshot one version while composing a different one.
    func effectiveSoulVersion(conversationID: String) throws -> SoulVersionRecord? {
        try database.read { db in
            try SoulVersionRecord.fetchOne(
                db,
                sql: """
                    SELECT soulVersion.id, soulVersion.instructions, soulVersion.createdAt
                    FROM soul
                    JOIN conversationSoulBinding AS binding
                      ON binding.conversationID = ?
                    JOIN soulVersion
                      ON soulVersion.id = binding.soulVersionID
                    WHERE soul.id = ? AND soul.enabled = 1
                    """,
                arguments: [conversationID, SoulRecord.globalID]
            )
        }
    }

    func soulVersion(id: String) throws -> SoulVersionRecord? {
        try database.read { db in
            try SoulVersionRecord.fetchOne(db, key: id)
        }
    }
}

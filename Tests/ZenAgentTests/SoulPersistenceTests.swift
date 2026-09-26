import Foundation
import GRDB
import Testing

@testable import ZenAgent

@Suite("Soul version persistence")
struct SoulPersistenceTests {
    private func version(_ id: String, _ instructions: String) -> SoulVersionRecord {
        SoulVersionRecord(id: id, instructions: instructions, createdAt: Fixtures.epoch)
    }

    @Test("an edit advances the current Soul without changing its prior version")
    func advancingPreservesOldVersion() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        #expect(try store.currentSoulVersion() == nil)

        try store.createSoul(initialVersion: version("v1", "Answer briefly"), at: Fixtures.epoch)
        try store.advanceSoul(
            expectedCurrentVersionID: "v1",
            to: version("v2", "Answer in detail"),
            at: Fixtures.epoch.addingTimeInterval(1)
        )

        #expect(try store.currentSoulVersion()?.id == "v2")
        #expect(try store.currentSoulVersion()?.instructions == "Answer in detail")
        #expect(try store.soulVersion(id: "v1")?.instructions == "Answer briefly")
    }

    @Test("a stale edit or duplicate version cannot move the current pointer")
    func rejectedEditLeavesCurrentVersionIntact() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.createSoul(initialVersion: version("v1", "Original"), at: Fixtures.epoch)
        try store.advanceSoul(
            expectedCurrentVersionID: "v1",
            to: version("v2", "Current"),
            at: Fixtures.epoch.addingTimeInterval(1)
        )

        #expect(throws: PersistenceError.soulEditConflict(expected: "v1", actual: "v2")) {
            try store.advanceSoul(
                expectedCurrentVersionID: "v1",
                to: version("v3", "Stale"),
                at: Fixtures.epoch.addingTimeInterval(2)
            )
        }
        #expect(try store.soulVersion(id: "v3") == nil)
        #expect(throws: PersistenceError.constraintViolation) {
            try store.advanceSoul(
                expectedCurrentVersionID: "v2",
                to: version("v1", "Overwrite"),
                at: Fixtures.epoch.addingTimeInterval(2)
            )
        }
        #expect(try store.currentSoulVersion()?.id == "v2")
        #expect(try store.soulVersion(id: "v1")?.instructions == "Original")
    }

    @Test("v9 Conversation data survives migration and Soul versions survive reopening")
    func migrationAndDiskReopen() throws {
        let url = try Fixtures.scratchPath(name: "soul-v9-upgrade.sqlite")
        defer { Fixtures.cleanUp(url) }

        do {
            var migrator = DatabaseMigrator()
            Migrations.registerV1(&migrator)
            Migrations.registerV2(&migrator)
            Migrations.registerV3(&migrator)
            Migrations.registerV4(&migrator)
            Migrations.registerV5(&migrator)
            Migrations.registerV6(&migrator)
            Migrations.registerV7(&migrator)
            Migrations.registerV8(&migrator)
            Migrations.registerV9(&migrator)
            let old = try ZenDatabase.open(at: url.path, migrator: migrator)
            try old.write { db in
                try Fixtures.conversation(id: "existing").insert(db)
            }
        }

        do {
            let store = PersistenceStore(database: try ZenDatabase.open(at: url.path))
            #expect(try store.conversation(id: "existing") != nil)
            try store.createSoul(initialVersion: version("v1", "Saved"), at: Fixtures.epoch)
        }
        let reopened = PersistenceStore(database: try ZenDatabase.open(at: url.path))
        #expect(try reopened.conversation(id: "existing") != nil)
        #expect(try reopened.currentSoulVersion()?.instructions == "Saved")
        #expect(try reopened.soulVersion(id: "v1")?.instructions == "Saved")
    }

    @Test("a stored SoulVersion cannot be edited in place")
    func versionRowsRejectUpdate() throws {
        let database = try ZenDatabase.inMemory()
        let store = PersistenceStore(database: database)
        try store.createSoul(initialVersion: version("v1", "Original"), at: Fixtures.epoch)
        #expect(throws: DatabaseError.self) {
            try database.write { db in
                try db.execute(
                    sql: "UPDATE soulVersion SET instructions = ? WHERE id = ?",
                    arguments: ["Rewritten", "v1"]
                )
            }
        }
        #expect(try store.soulVersion(id: "v1")?.instructions == "Original")
    }

    @Test("a prior SoulVersion cannot be deleted by an ordinary database write")
    func priorVersionRowsRejectDelete() throws {
        let database = try ZenDatabase.inMemory()
        let store = PersistenceStore(database: database)
        try store.createSoul(initialVersion: version("v1", "Original"), at: Fixtures.epoch)
        try store.advanceSoul(
            expectedCurrentVersionID: "v1",
            to: version("v2", "Current"),
            at: Fixtures.epoch.addingTimeInterval(1)
        )
        #expect(throws: DatabaseError.self) {
            try database.write { db in
                try db.execute(sql: "DELETE FROM soulVersion WHERE id = ?", arguments: ["v1"])
            }
        }
        #expect(try store.soulVersion(id: "v1")?.instructions == "Original")
    }

    @Test("a pointer update failure rolls back the already inserted version")
    func pointerFailureRollsBackVersionInsert() throws {
        let database = try ZenDatabase.inMemory()
        let store = PersistenceStore(database: database)
        try store.createSoul(initialVersion: version("v1", "Original"), at: Fixtures.epoch)
        try database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER soul_test_reject_pointer_update
                BEFORE UPDATE ON soul
                BEGIN
                    SELECT RAISE(ABORT, 'injected pointer failure');
                END
                """)
        }

        #expect(throws: PersistenceError.constraintViolation) {
            try store.advanceSoul(
                expectedCurrentVersionID: "v1",
                to: version("v2", "Must roll back"),
                at: Fixtures.epoch.addingTimeInterval(1)
            )
        }
        #expect(try store.currentSoulVersion()?.id == "v1")
        #expect(try store.soulVersion(id: "v2") == nil)
    }
}

import Foundation
import GRDB
import Testing

@testable import ZenAgent

@Suite("Conversation Soul binding")
struct SoulBindingTests {
    private func version(_ id: String, _ instructions: String) -> SoulVersionRecord {
        SoulVersionRecord(id: id, instructions: instructions, createdAt: Fixtures.epoch)
    }

    private func makeStore() throws -> PersistenceStore {
        PersistenceStore(database: try ZenDatabase.inMemory())
    }

    @Test("first Send pins a SoulVersion and later global edits do not rebind it")
    func firstSendPinsVersion() throws {
        let store = try makeStore()
        try store.createSoul(initialVersion: version("v1", "Brief"), at: Fixtures.epoch)

        try store.commitUserTurnAndCreateParentRun(
            Fixtures.send(conversationID: "old", messageID: "old-message", runID: "old-run")
        )
        try store.advanceSoul(
            expectedCurrentVersionID: "v1",
            to: version("v2", "Detailed"),
            at: Fixtures.epoch.addingTimeInterval(1)
        )
        try store.commitUserTurnAndCreateParentRun(
            Fixtures.send(conversationID: "new", messageID: "new-message", runID: "new-run")
        )

        #expect(try store.boundSoulVersion(conversationID: "old")?.id == "v1")
        #expect(try store.boundSoulVersion(conversationID: "old")?.instructions == "Brief")
        #expect(try store.boundSoulVersion(conversationID: "new")?.id == "v2")
        #expect(try store.run(id: "old-run") != nil)
        #expect(try store.run(id: "new-run") != nil)

        #expect(throws: PersistenceError.constraintViolation) {
            try store.commitUserTurnAndCreateParentRun(
                Fixtures.send(conversationID: "old", messageID: "old-message", runID: "replayed-run")
            )
        }
        #expect(try store.boundSoulVersion(conversationID: "old")?.id == "v1")
    }

    @Test("turning Soul off preserves old bindings but leaves new Conversations unbound")
    func disabledCreationDoesNotBind() throws {
        let store = try makeStore()
        try store.createSoul(initialVersion: version("v1", "Original"), at: Fixtures.epoch)
        try store.commitUserTurnAndCreateParentRun(
            Fixtures.send(conversationID: "before", messageID: "m-before", runID: "r-before")
        )

        try store.setSoulEnabled(false, at: Fixtures.epoch.addingTimeInterval(1))
        try store.commitUserTurnAndCreateParentRun(
            Fixtures.send(conversationID: "while-off", messageID: "m-off", runID: "r-off")
        )
        #expect(try store.soul()?.enabled == false)
        #expect(try store.currentSoulVersion()?.id == "v1")
        #expect(try store.boundSoulVersion(conversationID: "before")?.id == "v1")
        #expect(try store.boundSoulVersion(conversationID: "while-off") == nil)

        try store.setSoulEnabled(true, at: Fixtures.epoch.addingTimeInterval(2))
        try store.advanceSoul(
            expectedCurrentVersionID: "v1",
            to: version("v2", "New default"),
            at: Fixtures.epoch.addingTimeInterval(3)
        )
        try store.commitUserTurnAndCreateParentRun(
            Fixtures.send(conversationID: "after", messageID: "m-after", runID: "r-after")
        )
        #expect(try store.boundSoulVersion(conversationID: "before")?.id == "v1")
        #expect(try store.boundSoulVersion(conversationID: "while-off") == nil)
        #expect(try store.boundSoulVersion(conversationID: "after")?.id == "v2")
    }

    @Test("a failed first Send rolls back its Conversation and Soul binding")
    func failedSendRollsBackBinding() throws {
        let store = try makeStore()
        try store.createSoul(initialVersion: version("v1", "Original"), at: Fixtures.epoch)
        var commit = Fixtures.send(messageID: "m1", runID: "r1")
        commit.attachments = [MessageAttachmentRecord(
            id: "missing-attachment",
            messageID: "m1",
            assetID: "missing-asset",
            versionID: "missing-version",
            sequence: 0
        )]

        #expect(throws: PersistenceError.fileAssetNotFound("missing-asset")) {
            try store.commitUserTurnAndCreateParentRun(commit)
        }
        #expect(try store.conversation(id: "c1") == nil)
        #expect(try store.run(id: "r1") == nil)
        let bindingCount = try store.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversationSoulBinding") ?? -1
        }
        #expect(bindingCount == 0)
    }

    @Test("undo keeps a binding and finalized deletion removes it")
    func deletionLifecycleHandlesBinding() throws {
        let store = try makeStore()
        try store.createSoul(initialVersion: version("v1", "Original"), at: Fixtures.epoch)
        try store.commitUserTurnAndCreateParentRun(Fixtures.send(messageID: "m1", runID: "r1"))

        try store.beginDeletion(conversationID: "c1")
        #expect(try store.boundSoulVersion(conversationID: "c1")?.id == "v1")
        try store.undoDeletion(conversationID: "c1")
        #expect(try store.boundSoulVersion(conversationID: "c1")?.id == "v1")
        try store.beginDeletion(conversationID: "c1")
        try store.finalizeDeletion(conversationID: "c1")
        #expect(try store.boundSoulVersion(conversationID: "c1") == nil)
        #expect(try store.soulVersion(id: "v1")?.instructions == "Original")
    }

    @Test("v10 upgrade leaves existing Conversations unbound and keeps Soul enabled")
    func migrationPreservesExistingConversations() throws {
        let url = try Fixtures.scratchPath(name: "soul-binding-v10-upgrade.sqlite")
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
            Migrations.registerV10(&migrator)
            let old = try ZenDatabase.open(at: url.path, migrator: migrator)
            try old.write { db in
                try Fixtures.conversation(id: "existing").insert(db)
                try db.execute(sql: """
                    INSERT INTO soulVersion (id, instructions, createdAt) VALUES (?, ?, ?)
                    """, arguments: ["v1", "Original", Fixtures.epoch])
                try db.execute(sql: """
                    INSERT INTO soul (id, currentVersionID, updatedAt) VALUES (?, ?, ?)
                    """, arguments: ["global", "v1", Fixtures.epoch])
            }
        }

        let store = PersistenceStore(database: try ZenDatabase.open(at: url.path))
        #expect(try store.conversation(id: "existing") != nil)
        #expect(try store.soul()?.enabled == true)
        #expect(try store.boundSoulVersion(conversationID: "existing") == nil)
        try store.commitUserTurnAndCreateParentRun(
            Fixtures.send(conversationID: "new", messageID: "m-new", runID: "r-new")
        )
        #expect(try store.boundSoulVersion(conversationID: "new")?.id == "v1")
    }
}

import Foundation
import Testing
import GRDB

@testable import ZenAgent

@Suite("App Space deletion deadline")
struct AppSpaceDeletionDeadlineTests {
    @Test("the ten-second Undo deadline survives a database reopen and restores the complete body")
    func deadlineAndUndoSurviveReopen() throws {
        let url = try Fixtures.scratchPath(name: "card-undo.sqlite")
        defer { Fixtures.cleanUp(url) }
        let started = Fixtures.epoch.addingTimeInterval(100)

        do {
            let store = PersistenceStore(database: try ZenDatabase.open(at: url.path()))
            try store.commitUserTurnAndCreateParentRun(
                Fixtures.send(messageID: "undo-m1", runID: "undo-r1", runState: .completed)
            )
            let pending = try store.beginCardDeletion(conversationID: "c1", at: started)
            #expect(pending.conversationID == "c1")
            #expect(pending.deadline == started.addingTimeInterval(10))
            #expect(try store.conversationLifecycle(id: "c1") == .pendingDeletion)
            #expect(try store.messages(inConversation: "c1").count == 1)
        }

        let reopened = PersistenceStore(database: try ZenDatabase.open(at: url.path()))
        #expect(try reopened.pendingCardDeletion(id: "c1")?.deadline == started.addingTimeInterval(10))
        try reopened.undoCardDeletion(conversationID: "c1", at: started.addingTimeInterval(9))
        #expect(try reopened.conversationLifecycle(id: "c1") == .visible)
        #expect(try reopened.messages(inConversation: "c1").count == 1)
        #expect(try reopened.pendingCardDeletion(id: "c1") == nil)
    }

    @Test("Undo expires at the original deadline and only then may finalization remove the body")
    func expiryDoesNotResetOnAttempt() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.commitUserTurnAndCreateParentRun(
            Fixtures.send(messageID: "expired-m1", runID: "expired-r1", runState: .completed)
        )
        let started = Fixtures.epoch.addingTimeInterval(100)
        _ = try store.beginCardDeletion(conversationID: "c1", at: started)

        #expect(try !store.finalizeExpiredCardDeletion(conversationID: "c1", at: started.addingTimeInterval(9)))
        #expect(try store.messages(inConversation: "c1").count == 1)
        var undoFailure: Error?
        do { try store.undoCardDeletion(conversationID: "c1", at: started.addingTimeInterval(10)) }
        catch { undoFailure = error }
        #expect(undoFailure != nil)
        #expect(try store.conversationLifecycle(id: "c1") == .pendingDeletion)
        #expect(try store.finalizeExpiredCardDeletion(conversationID: "c1", at: started.addingTimeInterval(10)))
        #expect(try store.conversationLifecycle(id: "c1") == .finalizedDeletion)
        #expect(try store.messages(inConversation: "c1").isEmpty)
        #expect(try store.pendingCardDeletion(id: "c1") == nil)
    }

    @Test("a failed deadline insert cannot hide the card or lose its body")
    func deadlineWriteFailureRollsBackLifecycle() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.commitUserTurnAndCreateParentRun(
            Fixtures.send(messageID: "atomic-m1", runID: "atomic-r1", runState: .completed)
        )
        try store.database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_card_deadline BEFORE INSERT ON conversationDeletionDeadline
                BEGIN SELECT RAISE(ABORT, 'test deadline failure'); END
                """)
        }
        #expect(throws: (any Error).self) {
            _ = try store.beginCardDeletion(conversationID: "c1", at: Fixtures.epoch)
        }
        #expect(try store.conversationLifecycle(id: "c1") == .visible)
        #expect(try store.messages(inConversation: "c1").count == 1)
    }

    @Test("v12 pending deletion survives upgrade without an invented Card Undo deadline")
    func upgradePreservesLegacyPendingDeletion() throws {
        let url = try Fixtures.scratchPath(name: "card-deadline-upgrade.sqlite")
        defer { Fixtures.cleanUp(url) }
        var old = DatabaseMigrator()
        Migrations.registerV1(&old)
        Migrations.registerV2(&old)
        Migrations.registerV3(&old)
        Migrations.registerV4(&old)
        Migrations.registerV5(&old)
        Migrations.registerV6(&old)
        Migrations.registerV7(&old)
        Migrations.registerV8(&old)
        Migrations.registerV9(&old)
        Migrations.registerV10(&old)
        Migrations.registerV11(&old)
        Migrations.registerV12(&old)
        do {
            let before = PersistenceStore(database: try ZenDatabase.open(at: url.path(), migrator: old))
            try before.commitUserTurnAndCreateParentRun(
                Fixtures.send(messageID: "legacy-m1", runID: "legacy-r1", runState: .completed)
            )
            try before.beginDeletion(conversationID: "c1", at: Fixtures.epoch)
        }
        let after = PersistenceStore(database: try ZenDatabase.open(at: url.path()))
        #expect(try after.conversationLifecycle(id: "c1") == .pendingDeletion)
        #expect(try after.messages(inConversation: "c1").count == 1)
        #expect(try after.pendingCardDeletion(id: "c1") == nil)
    }

    @Test("cold start pages persisted intents without loading conversation bodies")
    func pendingIntentPageSurvivesReopen() throws {
        let url = try Fixtures.scratchPath(name: "card-intent-page.sqlite")
        defer { Fixtures.cleanUp(url) }
        do {
            let store = PersistenceStore(database: try ZenDatabase.open(at: url.path()))
            try store.createEmptyConversation(id: "a", at: Fixtures.epoch)
            try store.createEmptyConversation(id: "b", at: Fixtures.epoch)
            _ = try store.beginCardDeletion(conversationID: "a", at: Fixtures.epoch)
            _ = try store.beginCardDeletion(conversationID: "b", at: Fixtures.epoch.addingTimeInterval(1))
        }
        let reopened = PersistenceStore(database: try ZenDatabase.open(at: url.path()))
        let first = try reopened.pendingCardDeletionPage(limit: 1)
        #expect(first.map(\.conversationID) == ["a"])
        let second = try reopened.pendingCardDeletionPage(after: first.first, limit: 1)
        #expect(second.map(\.conversationID) == ["b"])
        #expect(try reopened.pendingCardDeletionPage(after: second.first, limit: 1).isEmpty)
    }
}

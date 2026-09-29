import Foundation
import Testing

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
}

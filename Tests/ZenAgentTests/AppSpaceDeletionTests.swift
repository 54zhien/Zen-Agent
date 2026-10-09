import Foundation
import Testing

@testable import ZenAgent

@Suite("App Space deletion lifecycle")
struct AppSpaceDeletionTests {
    @Test("a conversation holding an active Parent slot cannot enter the undo window")
    func activeRunMustSettleBeforePendingDeletion() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.commitUserTurnAndCreateParentRun(Fixtures.send(messageID: "delete-m1", runID: "delete-r1"))

        var failure: Error?
        do {
            try store.beginDeletion(conversationID: "c1", at: Fixtures.epoch.addingTimeInterval(20))
        } catch {
            failure = error
        }

        #expect(failure != nil, "Delete must wait until Runtime Stop releases the active slot")
        #expect(try store.conversationLifecycle(id: "c1") == .visible)
        #expect(try store.activeParentRuns(inConversation: "c1").count == 1)
        #expect(try store.messages(inConversation: "c1").count == 1)
    }
}

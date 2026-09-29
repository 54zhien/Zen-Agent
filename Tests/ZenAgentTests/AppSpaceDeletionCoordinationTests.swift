import Foundation
import Testing

@testable import ZenAgent

private enum CardStopFailure: Error { case injected }

@Suite("App Space Delete coordinates the real Run lifecycle")
@MainActor
struct AppSpaceDeletionCoordinationTests {
    @Test("Stop and terminal settlement precede a durable Card Delete")
    func waitsForTerminalRun() async throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.commitUserTurnAndCreateParentRun(
            Fixtures.send(messageID: "stop-m1", runID: "stop-r1")
        )
        var order: [String] = []
        let owner = AppSpaceConversationDeletion(store: store,
            stopRun: { runID in
                order.append("stop")
                #expect(try store.conversationLifecycle(id: "c1") == .visible)
                try store.transitionRun(id: runID, expectedState: .preparing, to: .stopping)
            },
            waitForRun: { runID in
                order.append("settle")
                #expect(try store.conversationLifecycle(id: "c1") == .visible)
                try store.transitionRun(id: runID, expectedState: .stopping,
                    to: .cancelled, endReason: .cancelledByUser)
            }, now: { Fixtures.epoch })

        #expect(await owner.delete(conversationID: "c1", stillSelected: { true }))
        #expect(order == ["stop", "settle"])
        #expect(try store.run(id: "stop-r1")?.state == .cancelled)
        #expect(try store.conversationLifecycle(id: "c1") == .pendingDeletion)
        #expect(try store.messages(inConversation: "c1").count == 1)
        #expect(owner.pending?.deadline == Fixtures.epoch.addingTimeInterval(10))
    }

    @Test("Stop failure leaves the selected body visible and retryable")
    func stopFailureCannotHideCard() async throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.commitUserTurnAndCreateParentRun(
            Fixtures.send(messageID: "failure-m1", runID: "failure-r1")
        )
        let owner = AppSpaceConversationDeletion(store: store,
            stopRun: { _ in throw CardStopFailure.injected },
            waitForRun: { _ in Issue.record("Wait must not follow failed Stop") },
            now: { Fixtures.epoch })
        #expect(!(await owner.delete(conversationID: "c1", stillSelected: { true })))
        #expect(try store.conversationLifecycle(id: "c1") == .visible)
        #expect(try store.messages(inConversation: "c1").count == 1)
        #expect(try store.activeParentRuns(inConversation: "c1").count == 1)
        #expect(owner.errorMessage != nil)
    }

    @Test("selection change during Stop cannot delete the formerly selected card")
    func staleSelectionCannotDelete() async throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.commitUserTurnAndCreateParentRun(
            Fixtures.send(messageID: "stale-m1", runID: "stale-r1")
        )
        var selected = true
        let owner = AppSpaceConversationDeletion(store: store,
            stopRun: { runID in
                try store.transitionRun(id: runID, expectedState: .preparing, to: .stopping)
                selected = false
            },
            waitForRun: { runID in
                try store.transitionRun(id: runID, expectedState: .stopping,
                    to: .cancelled, endReason: .cancelledByUser)
            }, now: { Fixtures.epoch })
        #expect(!(await owner.delete(conversationID: "c1", stillSelected: { selected })))
        #expect(try store.conversationLifecycle(id: "c1") == .visible)
        #expect(try store.run(id: "stale-r1")?.state == .cancelled)
    }
}

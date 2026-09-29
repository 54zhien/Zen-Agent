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

    @Test("Undo restores the body without restarting a cancelled Run")
    func ownerUndoRestoresBodyOnly() async throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.commitUserTurnAndCreateParentRun(
            Fixtures.send(messageID: "restore-m1", runID: "restore-r1")
        )
        try store.transitionRun(id: "restore-r1", expectedState: .preparing, to: .stopping)
        try store.transitionRun(id: "restore-r1", expectedState: .stopping,
            to: .cancelled, endReason: .cancelledByUser)
        let owner = AppSpaceConversationDeletion(store: store,
            stopRun: { _ in Issue.record("terminal Run must not be stopped again") },
            waitForRun: { _ in Issue.record("terminal Run must not be waited again") },
            now: { Fixtures.epoch })
        #expect(await owner.delete(conversationID: "c1", stillSelected: { true }))
        #expect(owner.undo(conversationID: "c1"))
        #expect(try store.conversationLifecycle(id: "c1") == .visible)
        #expect(try store.messages(inConversation: "c1").count == 1)
        #expect(try store.run(id: "restore-r1")?.state == .cancelled)
        #expect(owner.pending == nil)
    }

    @Test("a new owner recovers the original deadline from disk")
    func coldStartRecoversPendingIntent() throws {
        let url = try Fixtures.scratchPath(name: "owner-undo-recovery.sqlite")
        defer { Fixtures.cleanUp(url) }
        let started = Fixtures.epoch
        do {
            let before = PersistenceStore(database: try ZenDatabase.open(at: url.path()))
            try before.createEmptyConversation(id: "c1", at: started)
            _ = try before.beginCardDeletion(conversationID: "c1", at: started)
        }
        let after = PersistenceStore(database: try ZenDatabase.open(at: url.path()))
        let owner = AppSpaceConversationDeletion(store: after,
            stopRun: { _ in }, waitForRun: { _ in },
            now: { started.addingTimeInterval(5) })
        owner.recoverPending()
        #expect(owner.pending?.conversationID == "c1")
        #expect(owner.pending?.deadline == started.addingTimeInterval(10))
        #expect(try after.conversationLifecycle(id: "c1") == .pendingDeletion)
    }

    @Test("foreground recovery without a live timer holds the body during clock uncertainty")
    func foregroundRecoveryKeepsBodyDuringClockJump() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.commitUserTurnAndCreateParentRun(
            Fixtures.send(messageID: "clock-m1", runID: "clock-r1", runState: .completed)
        )
        _ = try store.beginCardDeletion(conversationID: "c1", at: Fixtures.epoch)
        let owner = AppSpaceConversationDeletion(store: store,
            stopRun: { _ in }, waitForRun: { _ in },
            now: { Fixtures.epoch.addingTimeInterval(3600) })

        owner.recoverPending(afterLaunch: false)
        owner.retryFinalization(conversationID: "c1")

        #expect(try store.conversationLifecycle(id: "c1") == .pendingDeletion)
        #expect(try store.messages(inConversation: "c1").count == 1)
        #expect(owner.errorMessage != nil)
    }

    @Test("a live monotonic timer prevents manual cleanup after a forward clock jump")
    func liveTimerKeepsBodyDuringClockJump() async throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.commitUserTurnAndCreateParentRun(
            Fixtures.send(messageID: "live-clock-m1", runID: "live-clock-r1", runState: .completed)
        )
        var wall = Fixtures.epoch
        let owner = AppSpaceConversationDeletion(store: store,
            stopRun: { _ in }, waitForRun: { _ in }, now: { wall })
        #expect(await owner.delete(conversationID: "c1", stillSelected: { true }))

        wall = Fixtures.epoch.addingTimeInterval(3600)
        owner.retryFinalization(conversationID: "c1")

        #expect(try store.conversationLifecycle(id: "c1") == .pendingDeletion)
        #expect(try store.messages(inConversation: "c1").count == 1)
        #expect(owner.errorMessage != nil)
    }

    @Test("cold-start wall-clock jump cannot erase a recoverable body after grace")
    func coldStartClockJumpNeedsDecision() async throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.commitUserTurnAndCreateParentRun(
            Fixtures.send(messageID: "cold-clock-m1", runID: "cold-clock-r1", runState: .completed)
        )
        _ = try store.beginCardDeletion(conversationID: "c1", at: Fixtures.epoch)
        let owner = AppSpaceConversationDeletion(store: store,
            stopRun: { _ in }, waitForRun: { _ in },
            now: { Fixtures.epoch.addingTimeInterval(3600) })

        owner.recoverPending()
        try await Task.sleep(for: .seconds(10.2))

        #expect(try store.conversationLifecycle(id: "c1") == .pendingDeletion)
        #expect(try store.messages(inConversation: "c1").count == 1)
        #expect(owner.pending?.conversationID == "c1")
    }
}

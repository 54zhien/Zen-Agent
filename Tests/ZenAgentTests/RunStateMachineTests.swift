import Foundation
import Testing

@testable import ZenAgent

@Suite("Run state machine")
struct RunStateMachineTests {

    @Test("allows every Stage 2 state edge")
    func allowsEveryStage2StateEdge() {
        let edges: [(RunState, RunState)] = [
            (.preparing, .requestingModel),
            (.preparing, .stopping),
            (.preparing, .suspended),
            (.preparing, .failed),
            (.requestingModel, .streaming),
            (.requestingModel, .toolRequested),
            (.requestingModel, .stopping),
            (.requestingModel, .suspended),
            (.requestingModel, .failed),
            (.streaming, .toolRequested),
            (.streaming, .completed),
            (.streaming, .stopping),
            (.streaming, .suspended),
            (.streaming, .failed),
            (.toolRequested, .waitingForApproval),
            (.toolRequested, .executingTools),
            (.toolRequested, .stopping),
            (.toolRequested, .failed),
            (.waitingForApproval, .executingTools),
            (.waitingForApproval, .continuing),
            (.waitingForApproval, .stopping),
            (.waitingForApproval, .suspended),
            (.waitingForApproval, .failed),
            (.executingTools, .continuing),
            (.executingTools, .stopping),
            (.executingTools, .suspended),
            (.executingTools, .failed),
            (.continuing, .requestingModel),
            (.continuing, .stopping),
            (.continuing, .suspended),
            (.continuing, .failed),
            (.stopping, .cancelled),
            (.suspended, .recovering),
            (.suspended, .stopping),
            (.suspended, .failed),
            (.recovering, .preparing),
            (.recovering, .requestingModel),
            (.recovering, .waitingForApproval),
            (.recovering, .executingTools),
            (.recovering, .continuing),
            (.recovering, .stopping),
            (.recovering, .failed),
        ]

        for (from, to) in edges {
            #expect(
                RunStateMachine.canTransition(from: from, to: to),
                "expected \(from.rawValue) → \(to.rawValue) to be allowed"
            )
        }
    }

    @Test("terminal states have no outgoing edges")
    func terminalStatesHaveNoOutgoingEdges() {
        for terminal in [RunState.completed, .failed, .cancelled] {
            for next in RunState.allCases {
                #expect(
                    !RunStateMachine.canTransition(from: terminal, to: next),
                    "terminal state \(terminal.rawValue) must not transition to \(next.rawValue)"
                )
            }
        }
    }

    @Test("an invalid edge is rejected")
    func rejectsInvalidEdge() {
        var failure: Error?
        do {
            _ = try RunStateMachine.transition(from: .preparing, to: .completed)
        } catch {
            failure = error
        }

        #expect(failure != nil)
    }

    @Test("transitionRun compares the expected state and maintains the active slot")
    func transitionRunIsCompareAndSet() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.commitUserTurnAndCreateParentRun(
            Fixtures.send(messageID: "user-1", runID: "run-1")
        )

        let now = Date(timeIntervalSince1970: 1_760_000_200)
        try store.transitionRun(
            id: "run-1",
            expectedState: .preparing,
            to: .requestingModel,
            at: now
        )

        #expect(try store.run(id: "run-1")?.state == .requestingModel)
        #expect(try store.run(id: "run-1")?.activeSlot == "c1")
        #expect(try store.activeParentRuns(inConversation: "c1").count == 1)

        var failure: Error?
        do {
            try store.transitionRun(
                id: "run-1",
                expectedState: .preparing,
                to: .stopping,
                at: now
            )
        } catch {
            failure = error
        }

        guard let persistenceError = failure as? PersistenceError else {
            #expect(false, "expected a typed PersistenceError for a CAS miss")
            return
        }
        if case .invalidTransition = persistenceError {
            // Expected: the stale expected state cannot overwrite the current state.
        } else {
            #expect(false, "expected invalidTransition, got \(persistenceError)")
        }
        #expect(try store.run(id: "run-1")?.state == .requestingModel)
    }

    @Test("terminal transition requires an end reason and releases the slot")
    func terminalTransitionRequiresReason() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.commitUserTurnAndCreateParentRun(
            Fixtures.send(messageID: "user-1", runID: "run-1")
        )
        try store.transitionRun(id: "run-1", expectedState: .preparing, to: .requestingModel)
        try store.transitionRun(id: "run-1", expectedState: .requestingModel, to: .streaming)

        var missingReason: Error?
        do {
            try store.transitionRun(id: "run-1", expectedState: .streaming, to: .completed)
        } catch {
            missingReason = error
        }
        #expect(missingReason != nil)
        #expect(try store.activeParentRuns(inConversation: "c1").count == 1)

        try store.transitionRun(
            id: "run-1",
            expectedState: .streaming,
            to: .completed,
            endReason: .completed
        )
        #expect(try store.run(id: "run-1")?.activeSlot == nil)
        #expect(try store.activeParentRuns(inConversation: "c1").isEmpty)
    }

    @Test("suspended and recovering states require their recovery metadata")
    func validatesSuspensionMetadata() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.commitUserTurnAndCreateParentRun(
            Fixtures.send(messageID: "user-1", runID: "run-1")
        )

        var missingSuspensionMetadata: Error?
        do {
            try store.transitionRun(id: "run-1", expectedState: .preparing, to: .suspended)
        } catch {
            missingSuspensionMetadata = error
        }
        #expect(missingSuspensionMetadata != nil)

        try store.transitionRun(
            id: "run-1",
            expectedState: .preparing,
            to: .suspended,
            recoveryAction: .resume,
            suspendReason: .backgrounded
        )
        #expect(try store.run(id: "run-1")?.suspendReason == .backgrounded)
        #expect(try store.run(id: "run-1")?.recoveryAction == .resume)

        var missingRecoveryAction: Error?
        do {
            try store.transitionRun(
                id: "run-1",
                expectedState: .suspended,
                to: .recovering
            )
        } catch {
            missingRecoveryAction = error
        }
        #expect(missingRecoveryAction != nil)

        try store.transitionRun(
            id: "run-1",
            expectedState: .suspended,
            to: .recovering,
            recoveryAction: .resume
        )
        #expect(try store.run(id: "run-1")?.suspendReason == nil)
        #expect(try store.run(id: "run-1")?.recoveryAction == .resume)
    }
}

import Foundation
import Testing

@testable import ZenAgent

/// Product invariant: **a tool call that might have reached the outside world is never
/// re-run automatically.**
///
/// The whole thing rests on one ordering decision: the dispatch marker is committed
/// *before* the external call, not after. Committing it afterwards leaves a window
/// where the call happened but nothing recorded it, and recovery would run it again.
///
/// The cost of that decision is the opposite error — a call that never actually
/// happened gets reported as indeterminate — and the design errs in that direction
/// deliberately. A duplicated write is not recoverable; a false "we're not sure" is.
///
/// These tests cover persistence only. There is no registry, policy, approval flow or
/// executor in Stage 0, and none of them are needed to prove this.
@Suite("Tool dispatch recovery")
struct ToolDispatchRecoveryTests {

    private func makeStore() throws -> PersistenceStore {
        PersistenceStore(database: try ZenDatabase.inMemory())
    }

    private func makeRun(_ store: PersistenceStore) throws {
        try store.commitUserTurnAndCreateParentRun(Fixtures.send(messageID: "m1", runID: "r1"))
    }

    @Test("a call that was only prepared may be dispatched")
    func preparedCallMayDispatch() throws {
        let store = try makeStore()
        try makeRun(store)
        try store.createToolCall(Fixtures.toolCall(id: "t1", runID: "r1", state: .prepared))

        let pending = try store.toolCallsNeedingRecovery(inRun: "r1")
        #expect(pending.count == 1, "a prepared call must be surfaced for recovery")
        #expect(
            pending.first?.disposition == .mayDispatch,
            "nothing left the process, so re-deciding is safe"
        )
    }

    @Test("a dispatched call must be reported, never retried")
    func dispatchedCallMustNotBeRetried() throws {
        let store = try makeStore()
        try makeRun(store)
        try store.createToolCall(Fixtures.toolCall(id: "t1", runID: "r1", state: .prepared))

        // The marker is committed *before* the external call. The process then dies
        // somewhere after it.
        try store.markToolCallDispatched(id: "t1")

        let pending = try store.toolCallsNeedingRecovery(inRun: "r1")
        #expect(pending.count == 1, "a dispatched call must be surfaced for recovery")
        #expect(
            pending.first?.disposition == .mustReportIndeterminate,
            """
            a call that may have reached the outside world must never be re-dispatched. \
            Treating it as "probably didn't happen" is how a write gets applied twice.
            """
        )
    }

    @Test("a settled call is not surfaced for recovery")
    func settledCallsAreNotSurfaced() throws {
        let store = try makeStore()
        try makeRun(store)
        try store.createToolCall(Fixtures.toolCall(id: "t1", runID: "r1", state: .succeeded))
        try store.createToolCall(Fixtures.toolCall(id: "t2", runID: "r1", state: .notExecuted))
        try store.createToolCall(Fixtures.toolCall(id: "t3", runID: "r1", state: .rejected))

        #expect(
            try store.toolCallsNeedingRecovery(inRun: "r1").isEmpty,
            "nothing that already finished should be offered to recovery"
        )
    }

    @Test("notExecuted and cancelled are not the same state")
    func notExecutedDiffersFromCancelled() throws {
        let store = try makeStore()
        try makeRun(store)
        try store.createToolCall(Fixtures.toolCall(id: "never", runID: "r1", state: .notExecuted))
        try store.createToolCall(Fixtures.toolCall(id: "after", runID: "r1", state: .cancelled))

        // Both are terminal, so neither is offered to recovery — but they must remain
        // distinguishable on disk. Collapsing them loses the only record of whether an
        // external side effect could have occurred, which is exactly what the
        // indeterminate concept depends on.
        #expect(try store.toolCall(id: "never")?.state == .notExecuted)
        #expect(try store.toolCall(id: "after")?.state == .cancelled)
    }

    @Test("the dispatch marker survives a reopen")
    func dispatchMarkerIsDurable() throws {
        let url = try Fixtures.scratchPath(name: "recovery.sqlite")
        defer { Fixtures.cleanUp(url) }

        do {
            let store = PersistenceStore(database: try ZenDatabase.open(at: url.path()))
            try makeRun(store)
            try store.createToolCall(Fixtures.toolCall(id: "t1", runID: "r1", state: .prepared))
            try store.markToolCallDispatched(id: "t1")
        }

        // A fresh store over the same file — what a restart leaves behind.
        let reopened = PersistenceStore(database: try ZenDatabase.open(at: url.path()))
        let pending = try reopened.toolCallsNeedingRecovery(inRun: "r1")

        #expect(
            pending.first?.call.state == .dispatched,
            "the marker must survive the restart; if it reverted to prepared, recovery would re-run a call that may have happened"
        )
        #expect(pending.first?.disposition == .mustReportIndeterminate)
    }

    @Test("the execution intent is frozen with the call")
    func executionIntentIsPersisted() throws {
        let store = try makeStore()
        try makeRun(store)
        try store.createToolCall(Fixtures.toolCall(id: "t1", runID: "r1", state: .prepared))

        let call = try store.toolCall(id: "t1")
        #expect(
            call?.executionIntent?.isEmpty == false,
            "a call without its frozen intent cannot be re-validated before dispatch, and an approval could be redirected"
        )
    }

    // The refusals below are probes: today every one of them reports success on a
    // zero-row update. The guarded mutations turn them into typed errors.

    @Test("a dispatch marker for a tool call that does not exist is refused")
    func dispatchMarkerForUnknownCallIsRefused() throws {
        let store = try makeStore()
        try makeRun(store)

        var failure: Error?
        do {
            try store.markToolCallDispatched(id: "never")
        } catch {
            failure = error
        }

        // Typed `toolCallNotFound` once the case exists; today the update touches
        // no row and reports success either way.
        #expect(failure != nil, "a marker for a call that is not on disk must not report success")
    }

    @Test("a settled call must not be marked dispatched")
    func settledCallCannotBeDispatched() throws {
        let store = try makeStore()
        try makeRun(store)
        try store.createToolCall(Fixtures.toolCall(id: "t1", runID: "r1", state: .succeeded))

        var failure: Error?
        do {
            try store.markToolCallDispatched(id: "t1")
        } catch {
            failure = error
        }

        guard
            let failure = failure as? ZenAgent.PersistenceError,
            case .invalidTransition = failure
        else {
            Issue.record("expected invalidTransition, got \(String(describing: failure))")
            return
        }
    }

    @Test("finishing a tool call that does not exist is refused")
    func finishingUnknownCallIsRefused() throws {
        let store = try makeStore()
        try makeRun(store)

        var failure: Error?
        do {
            try store.finishToolCall(id: "never", state: .succeeded)
        } catch {
            failure = error
        }

        // Typed `toolCallNotFound` once the case exists; today the update touches
        // no row and reports success either way.
        #expect(failure != nil, "finishing a call that is not on disk must not report success")
    }

    @Test("an already settled call must not be finished again")
    func settledCallCannotBeFinishedAgain() throws {
        let store = try makeStore()
        try makeRun(store)
        try store.createToolCall(Fixtures.toolCall(id: "t1", runID: "r1", state: .succeeded))

        var failure: Error?
        do {
            try store.finishToolCall(id: "t1", state: .failed)
        } catch {
            failure = error
        }

        guard
            let failure = failure as? ZenAgent.PersistenceError,
            case .invalidTransition = failure
        else {
            Issue.record("expected invalidTransition, got \(String(describing: failure))")
            return
        }
    }

    @Test("finishing a tool call into a non-terminal state is refused")
    func finishRequiresTerminalState() throws {
        let store = try makeStore()
        try makeRun(store)
        try store.createToolCall(Fixtures.toolCall(id: "t1", runID: "r1", state: .dispatched))

        var failure: Error?
        do {
            try store.finishToolCall(id: "t1", state: .prepared)
        } catch {
            failure = error
        }

        guard
            let failure = failure as? ZenAgent.PersistenceError,
            case .invalidTransition = failure
        else {
            Issue.record("expected invalidTransition, got \(String(describing: failure))")
            return
        }
    }
}

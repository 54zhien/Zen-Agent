import Foundation
import Testing

// The only test file that imports GRDB, and deliberately so: one case below has to
// write to the database *bypassing the store* to show the constraint is load-bearing
// on its own. Testing it through the store would only prove the store checks first.
// The CI boundary rule covers `App/` — production code has no such exemption.
import GRDB

@testable import ZenAgent

/// Product invariant: **at most one active parent run per conversation**, where
/// "active" means any non-terminal state.
///
/// This is the invariant ADR-0001 turns on, so it is tested at two levels:
///
/// - through the store, which is how the app will actually reach it
/// - directly against the schema, which is the only way to show that the guarantee
///   does not rest on the store remembering to check
///
/// If only the first existed, the index could be dropped in a refactor and every test
/// would still pass — until the race it exists to prevent showed up in production.
@Suite("Active parent run uniqueness")
struct ActiveParentRunUniquenessTests {

    private func makeStore() throws -> PersistenceStore {
        PersistenceStore(database: try ZenDatabase.inMemory())
    }

    @Test("a second send into an occupied conversation is rejected")
    func secondSendIsRejected() throws {
        let store = try makeStore()
        try store.commitUserTurnAndCreateParentRun(Fixtures.send(messageID: "m1", runID: "r1"))

        var failure: Error?
        do {
            try store.commitUserTurnAndCreateParentRun(Fixtures.send(messageID: "m2", runID: "r2"))
        } catch {
            failure = error
        }

        #expect(
            failure as? ZenAgent.PersistenceError == .conversationAlreadyHasActiveRun(conversationID: "c1"),
            "expected rejection, got \(String(describing: failure))"
        )
        #expect(
            try store.activeParentRuns(inConversation: "c1").count == 1,
            "the conversation must still hold exactly one active run"
        )
    }

    @Test("every non-terminal state holds the slot", arguments: [
        RunState.preparing,
        .requestingModel,
        .streaming,
        .toolRequested,
        .waitingForApproval,
        .executingTools,
        .continuing,
        .stopping,
        .suspended,
        .recovering,
    ])
    func nonTerminalStatesHoldTheSlot(state: RunState) throws {
        let store = try makeStore()
        try store.commitUserTurnAndCreateParentRun(
            Fixtures.send(messageID: "m1", runID: "r1", runState: state)
        )

        // `stopping` and `suspended` are the ones worth spelling out: it is tempting to
        // treat a run the user has already stopped, or one that is asleep, as no longer
        // occupying the conversation. Doing so lets a second run start while the first
        // is still unwinding, which is the double-stream the invariant exists to stop.
        #expect(
            try store.activeParentRuns(inConversation: "c1").count == 1,
            "\(state.rawValue) is non-terminal and must hold the slot"
        )

        var failure: Error?
        do {
            try store.commitUserTurnAndCreateParentRun(Fixtures.send(messageID: "m2", runID: "r2"))
        } catch {
            failure = error
        }
        #expect(failure != nil, "a run in \(state.rawValue) must still block a second parent run")
    }

    @Test("a terminal run releases the slot", arguments: [
        (RunState.completed, EndReason.completed),
        (.failed, .providerFailed),
        (.cancelled, .cancelledByUser),
    ])
    func terminalStatesReleaseTheSlot(state: RunState, reason: EndReason) throws {
        let store = try makeStore()
        try store.commitUserTurnAndCreateParentRun(Fixtures.send(messageID: "m1", runID: "r1"))
        #expect(try store.activeParentRuns(inConversation: "c1").count == 1)

        try store.finishRun(id: "r1", state: state, endReason: reason)

        #expect(
            try store.activeParentRuns(inConversation: "c1").count == 0,
            "\(state.rawValue) is terminal and must release the slot"
        )

        // And the conversation accepts a new send.
        try store.commitUserTurnAndCreateParentRun(Fixtures.send(messageID: "m2", runID: "r2"))
        #expect(try store.activeParentRuns(inConversation: "c1").count == 1)
    }

    @Test("finishRun refuses a non-terminal state")
    func finishingRequiresTerminalState() throws {
        let store = try makeStore()
        try store.commitUserTurnAndCreateParentRun(Fixtures.send(messageID: "m1", runID: "r1"))

        var failure: Error?
        do {
            try store.finishRun(id: "r1", state: .suspended, endReason: .completed)
        } catch {
            failure = error
        }

        #expect(
            failure != nil,
            "finishing into a non-terminal state must be refused — otherwise the slot is released while the run is still alive"
        )
        #expect(
            try store.activeParentRuns(inConversation: "c1").count == 1,
            "a refused transition must leave the slot where it was"
        )
    }

    @Test("a child run does not occupy its parent's slot")
    func childRunsDoNotClaimTheSlot() throws {
        let store = try makeStore()
        try store.commitUserTurnAndCreateParentRun(Fixtures.send(messageID: "m1", runID: "parent"))

        // A child run is active too, but the per-conversation slot belongs to the
        // parent. If a child claimed it, the first subagent would collide with the run
        // that spawned it.
        var derived = Fixtures.run(
            id: "child",
            kind: .child,
            state: .streaming,
            parentRunID: "parent"
        )
        derived.activeSlot = PersistenceStore.activeSlot(for: derived)

        #expect(derived.activeSlot == nil, "a child run must never derive a slot")
        // Bound to a `let`: the write block is `@Sendable` and cannot capture the
        // mutable local above.
        let child = derived
        try store.database.write { db in try child.insert(db) }

        #expect(
            try store.activeParentRuns(inConversation: "c1").count == 1,
            "adding a child run must not change how many runs hold the slot"
        )
    }

    @Test("the database rejects a second active parent run with no help from the store")
    func databaseEnforcesTheInvariantAlone() throws {
        let store = try makeStore()

        // Two runs claiming the same conversation's slot, written straight to the
        // database. This is the case that matters: if it succeeded, the invariant would
        // be resting on the store's pre-check — application discipline — and any future
        // code path that writes a run without going through the store would break it
        // silently. The spike showed that is exactly how the alternative engine fails.
        var mutableFirst = Fixtures.run(id: "r1")
        mutableFirst.activeSlot = "c1"
        var mutableSecond = Fixtures.run(id: "r2")
        mutableSecond.activeSlot = "c1"
        let first = mutableFirst
        let second = mutableSecond

        var failure: Error?
        do {
            try store.database.write { db in
                try first.insert(db)
                try second.insert(db)
            }
        } catch {
            failure = error
        }

        #expect(
            failure != nil,
            "the partial unique index must reject a second active parent run even when the store's check is bypassed"
        )
        #expect(
            try store.activeParentRuns(inConversation: "c1").count == 0,
            "the rejected transaction must have rolled back entirely"
        )
    }

    @Test("many terminal runs coexist in a conversation")
    func terminalRunsDoNotCompete() throws {
        let store = try makeStore()

        // The conditional half of the constraint: SQL treats NULLs as distinct, so the
        // slot frees up for every finished run. If this broke, a conversation would be
        // limited to a single run for its whole lifetime.
        for index in 0..<5 {
            try store.commitUserTurnAndCreateParentRun(
                Fixtures.send(messageID: "m\(index)", runID: "r\(index)")
            )
            try store.finishRun(id: "r\(index)", state: .completed, endReason: .completed)
        }

        #expect(
            try store.activeParentRuns(inConversation: "c1").count == 0,
            "no run should still hold the slot"
        )
        #expect(
            try store.messages(inConversation: "c1").count == 5,
            "every completed run's message must still be there"
        )
    }

    @Test("finishRun for a run that does not exist is refused")
    func finishingUnknownRunIsRefused() throws {
        let store = try makeStore()

        var failure: Error?
        do {
            try store.finishRun(id: "typo", state: .completed, endReason: .completed)
        } catch {
            failure = error
        }

        // `runNotFound` exists but nothing throws it yet — today the update touches
        // no row and reports success, and the real run keeps the slot forever.
        #expect(
            failure as? ZenAgent.PersistenceError == .runNotFound("typo"),
            "finishing a run that is not on disk must not report success; got \(String(describing: failure))"
        )
    }

    @Test("a run that is already terminal must not be finished again")
    func terminalRunCannotBeFinishedAgain() throws {
        let store = try makeStore()
        try store.commitUserTurnAndCreateParentRun(Fixtures.send(messageID: "m1", runID: "r1"))
        try store.finishRun(id: "r1", state: .completed, endReason: .completed)

        var failure: Error?
        do {
            try store.finishRun(id: "r1", state: .failed, endReason: .providerFailed)
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
        #expect(
            try store.run(id: "r1")?.endReason == .completed,
            "a refused re-finish must leave the original outcome in place"
        )
    }

    @Test("a suspended run can still be finished")
    func suspendedRunCanBeFinished() throws {
        let store = try makeStore()
        try store.commitUserTurnAndCreateParentRun(
            Fixtures.send(messageID: "m1", runID: "r1", runState: .suspended)
        )

        try store.finishRun(id: "r1", state: .completed, endReason: .completed)

        #expect(
            try store.activeParentRuns(inConversation: "c1").isEmpty,
            "finishing a suspended run must release the slot like any other non-terminal state"
        )
    }
}

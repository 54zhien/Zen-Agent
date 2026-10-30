import Foundation
import Testing

@testable import ZenAgent

/// Product invariant: **an event that belongs to a superseded provider request is
/// rejected.**
///
/// A stopped or recovered run keeps receiving events for a while. Those events are
/// indistinguishable from live ones by their content — the only thing that separates
/// them is the identity they carry. Without a durable record of which request is
/// current, a late delta from a cancelled stream would be written into the message as
/// though the model had said it.
///
/// The rule that makes this answerable: **a replay is a new attempt of the same step,
/// never a continuation of the old one.**
@Suite("Agent step attempts")
struct AgentStepAttemptTests {

    /// Compile-time, not runtime: if these stop being `Sendable`, the streaming
    /// transport that is about to call them from another isolation domain will not
    /// compile, and it is better to find that here than at the point of use.
    private func requireSendable<T: Sendable>(_: T.Type) {}

    @Test("the store and its database are Sendable")
    func storeIsSendable() {
        requireSendable(PersistenceStore.self)
        requireSendable(ZenDatabase.self)
        requireSendable(RequestConfigSeed.self)
        requireSendable(AgentStepRecord.self)
        requireSendable(AttemptIdentity.self)
    }

    private func makeStore() throws -> PersistenceStore {
        PersistenceStore(database: try ZenDatabase.inMemory())
    }

    private func makeRun(_ store: PersistenceStore) throws {
        try store.commitUserTurnAndCreateParentRun(Fixtures.send(messageID: "m1", runID: "r1"))
    }

    @Test("the first attempt of a step is accepted")
    func firstAttemptIsAccepted() throws {
        let store = try makeStore()
        try makeRun(store)
        try store.recordStep(Fixtures.step(stepID: "s1", runID: "r1", attempt: 1))

        #expect(try store.accepts(AttemptIdentity(stepID: "s1", attempt: 1)))
    }

    @Test("after a replay, the old attempt is rejected and the new one accepted")
    func replaySupersedesTheOldAttempt() throws {
        let store = try makeStore()
        try makeRun(store)
        try store.recordStep(Fixtures.step(stepID: "s1", runID: "r1", attempt: 1))
        try store.recordStep(Fixtures.step(stepID: "s1", runID: "r1", attempt: 2))

        // The first request is still in flight somewhere. Its events must not land.
        #expect(
            try !store.accepts(AttemptIdentity(stepID: "s1", attempt: 1)),
            "a superseded attempt must be rejected — this is the check that keeps a stopped stream's late delta out of the message"
        )
        #expect(try store.accepts(AttemptIdentity(stepID: "s1", attempt: 2)))
    }

    @Test("reported usage and Provider timestamps stay with their request attempt")
    func providerMeasurementsBelongToTheirAttempt() throws {
        let store = try makeStore()
        try makeRun(store)
        let first = Fixtures.step(stepID: "s1", runID: "r1", attempt: 1)
        let second = Fixtures.step(stepID: "s1", runID: "r1", attempt: 2)
        try store.recordStep(first)
        try store.recordStep(second)

        let firstStart = Date(timeIntervalSince1970: 100)
        let firstFinish = Date(timeIntervalSince1970: 103)
        let secondStart = Date(timeIntervalSince1970: 104)
        try store.markProviderStepStarted(first.attemptIdentity, at: firstStart)
        try store.recordProviderUsage(
            ProviderTokenUsage(promptTokens: 0, completionTokens: nil, totalTokens: nil),
            for: first.attemptIdentity
        )
        try store.markProviderStepFinished(first.attemptIdentity, at: firstFinish)
        try store.markProviderStepStarted(second.attemptIdentity, at: secondStart)

        let attempts = try store.steps(inRun: "r1")
        #expect(attempts[0].providerStartedAt == firstStart)
        #expect(attempts[0].providerFinishedAt == firstFinish)
        #expect(attempts[0].reportedPromptTokens == 0)
        #expect(attempts[0].reportedCompletionTokens == nil)
        #expect(attempts[0].reportedTotalTokens == nil)
        #expect(attempts[1].providerStartedAt == secondStart)
        #expect(attempts[1].providerFinishedAt == nil)
        #expect(attempts[1].reportedPromptTokens == nil)
    }

    @Test("credential rejection persists its source with the auth-required suspension")
    func credentialFailureEvidenceAndSuspensionArePersistedTogether() throws {
        let store = try makeStore()
        try makeRun(store)
        try store.transitionRun(id: "r1", expectedState: .preparing, to: .requestingModel)
        let attempt = Fixtures.step(stepID: "s1", runID: "r1", attempt: 1)
        let startedAt = Date(timeIntervalSince1970: 100)
        try store.recordStep(attempt)
        try store.markProviderStepStarted(attempt.attemptIdentity, at: startedAt)

        let failedAt = startedAt.addingTimeInterval(1)
        try store.suspendRunForCredentialFailure(
            runID: "r1",
            expectedState: .requestingModel,
            attemptIdentity: attempt.attemptIdentity,
            source: .providerHTTP401,
            at: failedAt
        )

        let suspended = try #require(store.run(id: "r1"))
        let persistedAttempt = try #require(store.currentAttempt(ofStep: "s1"))
        #expect(suspended.state == .suspended)
        #expect(suspended.recoveryAction == .reprepare)
        #expect(suspended.suspendReason == .authRequired)
        #expect(persistedAttempt.credentialFailureSource == .providerHTTP401)
        #expect(persistedAttempt.credentialFailureAt == failedAt)
    }

    @Test("an identity for a step that was never recorded is rejected")
    func unknownStepIsRejected() throws {
        let store = try makeStore()
        try makeRun(store)

        // Rejected rather than accepted-by-default. A default of "accept" would turn
        // every bookkeeping mistake into corrupted message content, and the failure
        // would look like a provider bug.
        #expect(
            try !store.accepts(AttemptIdentity(stepID: "never-recorded", attempt: 1)),
            "an event for an unknown step must not be accepted"
        )
    }

    @Test("recording the same attempt twice is refused")
    func duplicateAttemptIsRefused() throws {
        let store = try makeStore()
        try makeRun(store)
        try store.recordStep(Fixtures.step(stepID: "s1", runID: "r1", attempt: 1))

        var failure: Error?
        do {
            try store.recordStep(Fixtures.step(stepID: "s1", runID: "r1", attempt: 1))
        } catch {
            failure = error
        }

        // Two rows for one attempt would make "which attempt is current" ambiguous,
        // and the identity check would start answering the wrong question.
        #expect(
            failure != nil,
            "the composite key must reject a second row for the same (step, attempt)"
        )
        #expect(try store.steps(inRun: "r1").count == 1)
    }

    @Test("attempt identity survives a reopen")
    func attemptIdentityIsDurable() throws {
        let url = try Fixtures.scratchPath(name: "step.sqlite")
        defer { Fixtures.cleanUp(url) }

        do {
            let store = PersistenceStore(database: try ZenDatabase.open(at: url.path()))
            try makeRun(store)
            try store.recordStep(Fixtures.step(stepID: "s1", runID: "r1", attempt: 1))
            try store.recordStep(Fixtures.step(stepID: "s1", runID: "r1", attempt: 2))
        }

        let reopened = PersistenceStore(database: try ZenDatabase.open(at: url.path()))
        #expect(
            try reopened.currentAttempt(ofStep: "s1")?.attempt == 2,
            "the current attempt must survive a restart, or recovery would resume listening to a request that is gone"
        )
        #expect(try !reopened.accepts(AttemptIdentity(stepID: "s1", attempt: 1)))
    }

    @Test("attempts of different steps do not interfere")
    func stepsAreIndependent() throws {
        let store = try makeStore()
        try makeRun(store)
        try store.recordStep(Fixtures.step(stepID: "s1", runID: "r1", sequence: 0, attempt: 2))
        try store.recordStep(Fixtures.step(stepID: "s2", runID: "r1", sequence: 1, attempt: 1))

        #expect(try store.accepts(AttemptIdentity(stepID: "s1", attempt: 2)))
        #expect(try store.accepts(AttemptIdentity(stepID: "s2", attempt: 1)))
        #expect(try !store.accepts(AttemptIdentity(stepID: "s1", attempt: 1)))
    }

    @Test("deleting a conversation removes its steps")
    func stepsFollowTheirRun() throws {
        let store = try makeStore()
        try makeRun(store)
        try store.recordStep(Fixtures.step(stepID: "s1", runID: "r1"))

        try store.finishRun(id: "r1", state: .cancelled, endReason: .cancelledByUser)
        try store.beginDeletion(conversationID: "c1")
        try store.finalizeDeletion(conversationID: "c1")

        #expect(
            try store.steps(inRun: "r1").isEmpty,
            "step bookkeeping follows the run it belongs to; it is not a survivor like the tombstone"
        )
    }
}

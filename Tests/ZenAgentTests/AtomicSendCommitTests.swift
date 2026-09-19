import Foundation
import Testing

@testable import ZenAgent

/// Product invariant: **a send commits entirely or not at all.**
///
/// These test Zen's rule, not GRDB's API surface. They should keep passing through a
/// GRDB version bump, a schema refactor, or a rewrite of the store's internals — the
/// thing being protected is that a user's send never leaves a conversation in a state
/// the Runtime can neither resume nor explain.
///
/// The half-state is the only failing shape, and it has two forms: a message with no
/// run, or a run with no message. Both are covered.
@Suite("Atomic send commit")
struct AtomicSendCommitTests {

    private func makeStore() throws -> PersistenceStore {
        PersistenceStore(database: try ZenDatabase.inMemory())
    }

    @Test("a send writes the message, its parts, the run, and the frozen seed together")
    func sendWritesEverything() throws {
        let store = try makeStore()

        try store.commitUserTurnAndCreateParentRun(
            Fixtures.send(messageID: "m1", runID: "r1")
        )

        let messages = try store.messages(inConversation: "c1")
        #expect(messages.count == 1, "the user message must be committed; found \(messages.count)")

        let run = try store.run(id: "r1")
        #expect(run != nil, "the parent run must be created alongside the message")
        // The seed is a typed field rather than a blob, so "is it present" is answered
        // by the type. What is worth asserting is that it names the provider and model
        // the run was frozen against — a run that cannot say what it was sent to cannot
        // be replayed or explained.
        #expect(run?.requestConfigSeed.providerInstanceID == "pi1")
        #expect(
            run?.requestConfigSeed.modelID == "deepseek-chat",
            "the frozen seed must name the model the run was sent to, not leave it to be re-derived from current settings"
        )
        #expect(
            run?.triggerMessageID == "m1",
            "the run must point back at the message that triggered it, or the conversation cannot be grouped"
        )
    }

    @Test("a replayed send writes nothing at all")
    func replayedSendLeavesNoTrace() throws {
        let store = try makeStore()
        try store.commitUserTurnAndCreateParentRun(Fixtures.send(messageID: "m1", runID: "r1"))

        // The same message id arrives again — a double tap, a retried command, a UI
        // event delivered twice. The message insert must fail, and the failure must
        // take the *whole* commit with it.
        var failure: Error?
        do {
            try store.commitUserTurnAndCreateParentRun(Fixtures.send(messageID: "m1", runID: "r2"))
        } catch {
            failure = error
        }
        #expect(failure != nil, "a replayed send must be rejected, not silently accepted")

        #expect(
            try store.messages(inConversation: "c1").count == 1,
            "the replay must not add a second message"
        )
        #expect(
            try store.run(id: "r2") == nil,
            """
            the run half of a failed commit must not survive. Finding r2 here means the \
            transaction committed partially, which is the half-state this invariant exists \
            to prevent.
            """
        )
    }

    @Test("a rejected send leaves neither half behind")
    func rejectedSendLeavesNothing() throws {
        let store = try makeStore()
        try store.commitUserTurnAndCreateParentRun(Fixtures.send(messageID: "m1", runID: "r1"))

        // Same conversation, brand new message and run. The conversation is occupied,
        // so this must fail — and must fail without writing the new message either.
        var failure: Error?
        do {
            try store.commitUserTurnAndCreateParentRun(Fixtures.send(messageID: "m2", runID: "r2"))
        } catch {
            failure = error
        }

        #expect(
            failure as? PersistenceError == .conversationAlreadyHasActiveRun(conversationID: "c1"),
            "expected the occupied-conversation error, got \(String(describing: failure))"
        )
        #expect(
            try store.messages(inConversation: "c1").count == 1,
            "a rejected send must not leave its message behind"
        )
        #expect(try store.run(id: "r2") == nil, "a rejected send must not leave its run behind")
    }

    @Test("the request config seed is not rewritten by a later snapshot")
    func seedSurvivesSnapshotCompletion() throws {
        let store = try makeStore()
        try store.commitUserTurnAndCreateParentRun(Fixtures.send(messageID: "m1", runID: "r1"))

        let seedAfterCommit = try store.run(id: "r1")?.requestConfigSeed

        // Preparing fills in the execution snapshot. It must not touch the seed — the
        // seed is what makes a run replayable after the user changes model settings.
        try store.database.write { db in
            try db.execute(
                sql: "UPDATE agentRun SET executionSnapshot = ? WHERE id = 'r1'",
                arguments: [#"{"coreVersion":"1"}"#]
            )
        }

        let after = try store.run(id: "r1")
        #expect(
            after?.requestConfigSeed == seedAfterCommit,
            "completing the execution snapshot must not rewrite the frozen request config seed"
        )
        #expect(after?.executionSnapshot != nil, "the snapshot itself must have been stored")
    }
}

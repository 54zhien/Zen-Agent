import Foundation
import Testing

@testable import ZenAgent

/// Product invariant: **during the undo window the body is intact, and undo restores
/// the complete conversation.**
///
/// The failing shape is an undo that returns an empty shell — the conversation comes
/// back and its messages do not. A boolean "isDeleted" flag cannot express a state
/// where a conversation is hidden but fully recoverable, which is why the lifecycle has
/// three values.
///
/// Asserted through persistence rather than through a UI, because the decision that
/// matters is what is still on disk while the card is off-screen.
@Suite("Conversation deletion")
struct ConversationDeletionTests {

    private func makeStore() throws -> PersistenceStore {
        PersistenceStore(database: try ZenDatabase.inMemory())
    }

    private func seeded() throws -> PersistenceStore {
        let store = try makeStore()
        try store.commitUserTurnAndCreateParentRun(Fixtures.send(messageID: "m1", runID: "r1"))
        return store
    }

    @Test("a pending-deletion conversation leaves ordinary listing")
    func pendingDeletionHidesIt() throws {
        let store = try seeded()
        #expect(try store.visibleConversations().count == 1)

        try store.beginDeletion(conversationID: "c1")

        #expect(
            try store.visibleConversations().isEmpty,
            "a pending-deletion conversation must not appear in ordinary listing"
        )
        #expect(try store.conversationLifecycle(id: "c1") == .pendingDeletion)
    }

    @Test("the undo window keeps the body")
    func undoWindowKeepsTheBody() throws {
        let store = try seeded()
        try store.beginDeletion(conversationID: "c1")

        // This is the assertion the whole three-state lifecycle exists for.
        #expect(
            try store.messages(inConversation: "c1").count == 1,
            """
            hiding a conversation must not discard its content — undo is supposed to \
            restore a conversation, not an empty shell
            """
        )
    }

    @Test("undo restores the complete conversation")
    func undoRestoresEverything() throws {
        let store = try seeded()
        try store.beginDeletion(conversationID: "c1")
        try store.undoDeletion(conversationID: "c1")

        #expect(try store.visibleConversations().count == 1, "undo must return it to ordinary listing")
        #expect(
            try store.messages(inConversation: "c1").count == 1,
            "undo must restore the complete conversation, not a shell"
        )
        #expect(try store.conversationLifecycle(id: "c1") == .visible)

        // And it is usable again: the run still holds the slot, so the conversation is
        // exactly where it was rather than half-alive.
        #expect(try store.activeParentRuns(inConversation: "c1").count == 1)
    }

    @Test("finalising removes the body")
    func finalizeRemovesTheBody() throws {
        let store = try seeded()
        try store.beginDeletion(conversationID: "c1")
        try store.finalizeDeletion(conversationID: "c1")

        #expect(
            try store.messages(inConversation: "c1").isEmpty,
            "finalising is the point the body goes"
        )
        #expect(try store.conversationLifecycle(id: "c1") == .finalizedDeletion)
        #expect(
            try store.visibleConversations().isEmpty,
            "a finalised conversation must not reappear in listing"
        )
    }

    @Test("undo is refused once the deletion has been finalised")
    func undoAfterFinalizeIsRefused() throws {
        let store = try seeded()
        try store.beginDeletion(conversationID: "c1")
        try store.finalizeDeletion(conversationID: "c1")

        // Finalising is one-way. Without a guard on the current state, undo would flip
        // the flag to `visible` over a body that no longer exists — a conversation that
        // claims to be there and has nothing in it.
        //
        // Caught while writing this test: the first version of `undoDeletion` wrote the
        // target state unconditionally, and the test asserting that behaviour would have
        // frozen the bug in place as though it were the design. The store guards the
        // transition instead, and this asserts the refusal.
        var failure: Error?
        do {
            try store.undoDeletion(conversationID: "c1")
        } catch {
            failure = error
        }

        #expect(
            failure != nil,
            "undoing a finalised deletion must be refused, not quietly flip the lifecycle back"
        )
        #expect(
            try store.conversationLifecycle(id: "c1") == .finalizedDeletion,
            "a refused undo must leave the lifecycle where it was"
        )
        #expect(try store.visibleConversations().isEmpty, "and must not put it back in listing")
    }

    @Test("beginning a deletion twice is refused")
    func beginDeletionTwiceIsRefused() throws {
        let store = try seeded()
        try store.beginDeletion(conversationID: "c1")

        var failure: Error?
        do {
            try store.beginDeletion(conversationID: "c1")
        } catch {
            failure = error
        }

        // Not cosmetic: a second begin would be harmless here, but the same
        // unconditional write is what made the finalised-undo defect possible. One
        // guarded transition beats two writes that happen to be safe today.
        #expect(failure != nil, "the lifecycle has no visible → pendingDeletion → pendingDeletion edge")
        #expect(try store.messages(inConversation: "c1").count == 1)
    }

    @Test("deleting a conversation that does not exist is refused")
    func deletingUnknownConversationFails() throws {
        let store = try makeStore()

        var failure: Error?
        do {
            try store.beginDeletion(conversationID: "missing")
        } catch {
            failure = error
        }

        #expect(
            failure as? ZenAgent.PersistenceError == .conversationNotFound("missing"),
            "expected a not-found error, got \(String(describing: failure))"
        )
    }
}

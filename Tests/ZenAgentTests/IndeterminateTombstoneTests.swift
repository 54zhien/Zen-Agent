import Foundation
import Testing

@testable import ZenAgent

/// Product invariant: **the record of an external operation that may have happened
/// outlives the conversation that held it.**
///
/// This is one of the few places in the design where a record has to survive its own
/// parent. The tombstone exists precisely because the thing that owned it is gone: an
/// external write was dispatched, its outcome is unknown, and the user has since
/// deleted the conversation. Forgetting it means losing the only evidence that a side
/// effect might have occurred.
///
/// It is also the constraint that made the schema declare no relationship at all
/// between the tombstone and the conversation — any cascade path would delete the one
/// record that has to stay.
@Suite("Indeterminate tombstone")
struct IndeterminateTombstoneTests {

    private func makeStore() throws -> PersistenceStore {
        PersistenceStore(database: try ZenDatabase.inMemory())
    }

    /// A conversation holding one tool call in the given state.
    private func seeded(toolCallState: ToolCallState) throws -> PersistenceStore {
        let store = try makeStore()
        try store.commitUserTurnAndCreateParentRun(Fixtures.send(messageID: "m1", runID: "r1"))
        try store.createToolCall(
            Fixtures.toolCall(
                id: "t1",
                runID: "r1",
                action: "files.write",
                state: toolCallState,
                intent: #"{"action":"files.write","target":"file:n1"}"#
            )
        )
        return store
    }

    @Test("finalising leaves a tombstone for an indeterminate call")
    func tombstoneIsWrittenOnFinalize() throws {
        let store = try seeded(toolCallState: .indeterminate)
        try store.beginDeletion(conversationID: "c1")
        try store.finalizeDeletion(conversationID: "c1")

        let tombstone = try store.tombstone(toolCallID: "t1")
        #expect(tombstone != nil, "the indeterminate operation must leave a record")
        #expect(tombstone?.action == "files.write")
        #expect(
            tombstone?.destinationFingerprint.isEmpty == false,
            "the record must identify where the effect landed, or it cannot be investigated"
        )
        #expect(tombstone?.status == ToolCallState.indeterminate.rawValue)
    }

    @Test("the body is gone while the tombstone remains")
    func bodyGoesTombstoneStays() throws {
        let store = try seeded(toolCallState: .indeterminate)
        try store.beginDeletion(conversationID: "c1")
        try store.finalizeDeletion(conversationID: "c1")

        #expect(try store.messages(inConversation: "c1").isEmpty, "the body must be gone")
        #expect(
            try store.toolCalls(inRun: "r1").isEmpty,
            "the messages and the tool call are both gone; only the minimal record survives"
        )
        #expect(
            try store.tombstones().count == 1,
            """
            ...and it survives anyway. If this is zero, a cascade reached the one record \
            that exists because its parent is gone — the side effect is now untraceable.
            """
        )
    }

    @Test("a settled call leaves no tombstone")
    func settledCallsLeaveNoTombstone() throws {
        let store = try seeded(toolCallState: .succeeded)
        try store.beginDeletion(conversationID: "c1")
        try store.finalizeDeletion(conversationID: "c1")

        // Only uncertainty needs a record. Keeping one for every completed call would
        // turn a minimal trace into an archive of everything the user deleted.
        #expect(
            try store.tombstones().isEmpty,
            "a call with a known outcome must not leave a tombstone"
        )
    }

    @Test("finalising twice keeps one tombstone and does not fail")
    func finalizeIsIdempotent() throws {
        let store = try seeded(toolCallState: .indeterminate)
        try store.beginDeletion(conversationID: "c1")
        try store.finalizeDeletion(conversationID: "c1")
        try store.finalizeDeletion(conversationID: "c1")

        #expect(try store.tombstones().count == 1, "finalising twice must not duplicate the record")
        #expect(try store.tombstone(toolCallID: "t1")?.action == "files.write")
    }

    @Test("the tombstone survives the conversation being gone, across a reopen")
    func tombstoneSurvivesReopen() throws {
        let url = try Fixtures.scratchPath(name: "tombstone.sqlite")
        defer { Fixtures.cleanUp(url) }

        do {
            let store = PersistenceStore(database: try ZenDatabase.open(at: url.path()))
            try store.commitUserTurnAndCreateParentRun(Fixtures.send(messageID: "m1", runID: "r1"))
            try store.createToolCall(
                Fixtures.toolCall(id: "t1", runID: "r1", state: .indeterminate)
            )
            try store.beginDeletion(conversationID: "c1")
            try store.finalizeDeletion(conversationID: "c1")
        }

        let reopened = PersistenceStore(database: try ZenDatabase.open(at: url.path()))
        #expect(
            try reopened.tombstone(toolCallID: "t1") != nil,
            "the record must still be there after a restart, or the uncertainty is silently lost"
        )
        #expect(try reopened.messages(inConversation: "c1").isEmpty)
    }
}

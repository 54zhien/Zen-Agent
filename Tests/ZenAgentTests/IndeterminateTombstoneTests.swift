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
    ///
    /// `intent` is a parameter so a test can put something recognisable in it, and then
    /// check that nothing recognisable came out the other end.
    private func seeded(
        toolCallState: ToolCallState,
        intent: String = #"{"action":"files.write","target":"file:n1"}"#
    ) throws -> PersistenceStore {
        let store = try makeStore()
        try store.commitUserTurnAndCreateParentRun(Fixtures.send(messageID: "m1", runID: "r1"))
        try store.createToolCall(
            Fixtures.toolCall(
                id: "t1",
                runID: "r1",
                action: "files.write",
                state: toolCallState,
                intent: intent
            )
        )
        return store
    }

    @Test("finalising leaves a tombstone for an indeterminate call")
    func tombstoneIsWrittenOnFinalize() throws {
        // Recognisable, and unique to this test: if it turns up in the record, it can
        // only have been copied out of the intent. Nothing else in the store knows it.
        let marker = "destination-marker-2f7c9a"
        let intent = #"{"action":"files.write","target":"file:\#(marker)"}"#

        let store = try seeded(toolCallState: .indeterminate, intent: intent)
        try store.beginDeletion(conversationID: "c1")
        try store.finalizeDeletion(conversationID: "c1")

        let found = try store.tombstone(toolCallID: "t1")
        let tombstone = try #require(found, "the indeterminate operation must leave a record")
        #expect(tombstone.action == "files.write")
        #expect(tombstone.status == ToolCallState.indeterminate.rawValue)

        // The invariant, stated directly. The tombstone is the one record that outlives
        // its conversation, so it must not carry the conversation's body out with it:
        // the frozen intent names the exact target the executor was handed, and the
        // user's delete was supposed to end it.
        #expect(
            tombstone.destinationFingerprint != intent,
            "the record must not hold the frozen intent; that intent is the deleted conversation's body"
        )
        #expect(
            tombstone.destinationFingerprint.isEmpty == false,
            """
            ...but it must still be recorded as *something*. A blank destination cannot \
            even be triaged: "unknown" is a fact, "" is the absence of one.
            """
        )

        // Every string the row stores, one by one, so a leak names the column it is in...
        #expect(
            tombstone.destinationFingerprint.contains(marker) == false,
            "the destination fingerprint carries no part of the intent"
        )
        #expect(
            tombstone.action.contains(marker) == false,
            "the action is a restricted identifier, not the intent"
        )
        #expect(
            tombstone.status.contains(marker) == false,
            "the status is a state name, not the intent"
        )
        #expect(
            tombstone.toolCallID.contains(marker) == false,
            "the record is keyed by the call, not by its intent"
        )

        // ...and then the whole row at once, so a column added later cannot slip past the
        // list above. `destinationFingerprint` was exactly that column once.
        let row = try #require(String(data: JSONEncoder().encode(tombstone), encoding: .utf8))
        #expect(
            row.contains(marker) == false,
            "no part of the tombstone may quote the intent: it outlives the conversation the user deleted"
        )
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

    /// Every state, not just the two the rule names: the tombstone set must be derived
    /// from `recoveryDisposition`, so a state that later comes to mean "may have
    /// happened" starts producing tombstones without a change here.
    @Test("finalising writes a tombstone exactly for states that may have happened", arguments: ToolCallState.allCases)
    func tombstoneMatchesDisposition(state: ToolCallState) throws {
        let store = try seeded(toolCallState: state)
        try store.beginDeletion(conversationID: "c1")
        try store.finalizeDeletion(conversationID: "c1")

        let tombstone = try store.tombstone(toolCallID: "t1")
        let mustReport = state.recoveryDisposition == .mustReportIndeterminate
        #expect(
            (tombstone != nil) == mustReport,
            "\(state.rawValue): tombstone presence must match the recovery disposition"
        )
        if mustReport {
            #expect(
                tombstone?.status == state.rawValue,
                "the tombstone must record the state the call was found in"
            )
        }
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

import Foundation
import Testing

@testable import ZenAgent

/// Product invariant: **the loader reads a conversation and hands the projection a plain
/// value — it reorders nothing, and it invents nothing.**
///
/// These run against the real persistence layer: the real schema, the real constraints and
/// the real `ORDER BY`. That is the point of them. The ordering the reading layout depends
/// on is a property of the query, not of the caller, and a fake store would let a broken
/// query pass by handing back whatever the test happened to insert.
@Suite("Conversation timeline loader")
struct ConversationTimelineLoaderTests {

    private func makeStore() throws -> PersistenceStore {
        PersistenceStore(database: try ZenDatabase.inMemory())
    }

    /// A send whose run carries a chosen creation time, kind and text.
    ///
    /// `Fixtures.send` pins every record to the shared epoch, which makes it useless for a
    /// test about ordering or for telling one message's content from another's. This is the
    /// same commit assembled from the same fixture pieces — no record is hand-built — with
    /// those three left to the caller. The run state defaults to a terminal one so that
    /// several runs can share a conversation: the active-slot rule allows only one live
    /// parent run at a time, and that rule is not what these tests are about.
    private func send(
        at createdAt: Date = Fixtures.epoch,
        messageID: String,
        runID: String,
        conversationID: String = "c1",
        kind: RunKind = .parent,
        state: RunState = .completed,
        text: String = "hello"
    ) -> SendCommit {
        SendCommit(
            conversation: Fixtures.conversation(id: conversationID),
            message: Fixtures.message(id: messageID, conversationID: conversationID),
            parts: [Fixtures.textPart(id: "\(messageID)-p0", messageID: messageID, text: text)],
            run: Fixtures.run(
                id: runID,
                conversationID: conversationID,
                kind: kind,
                state: state,
                triggerMessageID: messageID,
                createdAt: createdAt,
                // Follows `createdAt` rather than staying at the shared epoch: the store
                // never writes a run whose last update precedes its creation, and a
                // fixture that did would be a row no real conversation can hold.
                updatedAt: createdAt
            )
        )
    }

    @Test("a sent turn and its assistant reply load as one turn")
    func sentTurnLoadsAsOneTurn() throws {
        let store = try makeStore()
        try store.commitUserTurnAndCreateParentRun(Fixtures.send(messageID: "m1", runID: "r1"))
        _ = try store.ensureAssistantResponse(forRunID: "r1", messageID: "m2")
        try store.createPart(Fixtures.textPart(id: "m2-p0", messageID: "m2", text: "the answer"))

        let projection = try ConversationTimelineLoader.load(conversationID: "c1", from: store)

        #expect(projection.conversationID == "c1")
        #expect(projection.turns.count == 1)
        #expect(projection.turns.first?.runID == "r1")
        #expect(
            projection.turns.first?.items == [.userText("hello"), .assistantText("the answer")],
            "the message and the response the store actually holds must come back as one turn"
        )
    }

    @Test("a conversation's runs are read without the other conversations' runs")
    func runsAreScopedToTheirConversation() throws {
        let store = try makeStore()
        try store.commitUserTurnAndCreateParentRun(
            Fixtures.send(conversationID: "c1", messageID: "m1", runID: "r1")
        )
        try store.commitUserTurnAndCreateParentRun(
            Fixtures.send(conversationID: "c2", messageID: "m2", runID: "r2")
        )

        #expect(try store.runs(inConversation: "c1").map(\.id) == ["r1"])
        #expect(try store.runs(inConversation: "c2").map(\.id) == ["r2"])
        #expect(
            try store.runs(inConversation: "c-absent").isEmpty,
            "a conversation with no runs must read as empty rather than as every run there is"
        )
    }

    @Test("runs come back oldest first, with same-instant runs ordered by id")
    func runsAreOrderedByCreationThenID() throws {
        let store = try makeStore()
        // Chosen so that the ids are not in the order the rows were written, and not in
        // the order of their timestamps either: a query that leaned on either would give a
        // different answer than the one asserted here.
        try store.commitUserTurnAndCreateParentRun(
            send(at: Fixtures.epoch.addingTimeInterval(120), messageID: "m2", runID: "r2")
        )
        try store.commitUserTurnAndCreateParentRun(
            send(at: Fixtures.epoch, messageID: "m3", runID: "r3")
        )
        try store.commitUserTurnAndCreateParentRun(
            send(at: Fixtures.epoch, messageID: "m1", runID: "r1")
        )

        #expect(
            try store.runs(inConversation: "c1").map(\.id) == ["r1", "r3", "r2"],
            """
            the tie-break is not decoration: two runs created in the same instant have no \
            order at all without it, and the timeline would render differently between \
            launches
            """
        )
    }

    @Test("a child run is neither a turn nor a source of turn content")
    func childRunProducesNoTurn() throws {
        let store = try makeStore()
        try store.commitUserTurnAndCreateParentRun(
            send(messageID: "m1", runID: "parent-r", text: "what the user asked")
        )
        try store.commitUserTurnAndCreateParentRun(
            send(messageID: "m2", runID: "child-r", kind: .child, text: "what the subagent said")
        )

        let projection = try ConversationTimelineLoader.load(conversationID: "c1", from: store)
        let items = projection.turns.flatMap(\.items)

        #expect(projection.turns.map(\.runID) == ["parent-r"])
        #expect(
            !items.contains(.userText("what the subagent said")),
            "the child run's message must not surface inside the parent's turn"
        )
        #expect(items.contains(.userText("what the user asked")))
    }

    @Test("tool results are read by call id, and an empty request reads none")
    func toolResultsAreReadByCallID() throws {
        let store = try makeStore()
        try store.commitUserTurnAndCreateParentRun(Fixtures.send(messageID: "m1", runID: "r1"))

        // Written through the real state machine rather than by inserting the result row:
        // a result exists only for a call that was dispatched, and a fixture that skipped
        // that would be testing a shape the store cannot produce.
        try store.createToolCall(Fixtures.toolCall(id: "tc1", runID: "r1"))
        try store.markToolCallDispatched(id: "tc1")
        try store.finishDispatchedToolCall(
            id: "tc1",
            expectedAttempt: 1,
            state: .succeeded,
            result: ToolResultRecord(toolCallID: "tc1", payload: #"{"ok":true}"#, createdAt: Fixtures.epoch)
        )
        // A second call that never produced a result.
        try store.createToolCall(Fixtures.toolCall(id: "tc2", runID: "r1"))

        #expect(
            try store.toolResults(forToolCallIDs: ["tc1", "tc2"]).map(\.toolCallID) == ["tc1"],
            "only the calls that have a result may come back"
        )
        #expect(try store.toolResults(forToolCallIDs: ["tc2"]).isEmpty)
        #expect(
            try store.toolResults(forToolCallIDs: []).isEmpty,
            "an empty request must answer empty rather than read the whole table"
        )
    }

    @Test("timeline reopens the saved quote snapshot after its source is deleted")
    func timelineReopensQuoteAfterSourceDeletion() throws {
        let store = try makeStore()
        try store.database.write { db in
            try Fixtures.conversation(id: "source-conversation").insert(db)
            try Fixtures.message(id: "source-message", conversationID: "source-conversation").insert(db)
            try MessagePartRecord(
                id: "source-part",
                messageID: "source-message",
                sequence: 0,
                kind: .text,
                state: .completed,
                payload: try PersistenceStore.encodeTextPayload(.init(text: "quoted snapshot"))
            ).insert(db)
        }

        var commit = Fixtures.send(messageID: "target-message", runID: "target-run")
        commit.quoteReferences = [
            MessageQuoteReferenceRecord(
                id: "target-quote",
                messageID: "target-message",
                sequence: 0,
                sourceConversationID: "source-conversation",
                sourceMessageID: "source-message",
                sourcePartID: "source-part",
                sourceUTF16Start: 0,
                sourceUTF16Length: 15,
                snapshot: "quoted snapshot",
                createdAt: Fixtures.epoch
            ),
        ]
        try store.commitUserTurnAndCreateParentRun(commit)
        try store.database.write { db in
            try db.execute(sql: "DELETE FROM conversation WHERE id = ?", arguments: ["source-conversation"])
        }

        let projection = try ConversationTimelineLoader.load(conversationID: "c1", from: store)
        let items = projection.turns.first?.items ?? []
        let quoteItems = items.compactMap { item -> [QuoteReferencePresentation]? in
            if case .quoteReferences(let references) = item { return references }
            return nil
        }.flatMap { $0 }
        #expect(quoteItems.count == 1)
        #expect(quoteItems[0].reference.snapshot == "quoted snapshot")
        #expect(!quoteItems[0].sourceIsAvailable)
        #expect(projection.turns.first?.textSourcesByItemIndex[0]?.partID == "target-message-p0")
    }
}

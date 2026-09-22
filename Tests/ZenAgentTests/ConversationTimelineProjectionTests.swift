import Foundation
import Testing

@testable import ZenAgent

/// Product invariant: **a Turn is one parent run, and its content is exactly what that
/// run's messages contain.**
///
/// The projection is a pure function over real record types, so these tests build inputs
/// from the same `AgentRunRecord` / `MessageRecord` / `MessagePartRecord` values the store
/// writes — with real payload JSON, not mocks. What they pin down is the shape of the
/// rules the reading layout rests on:
///
/// - one parent run is one turn; a child run is not a turn at all;
/// - a run that produced no assistant message gets a run notice, **never** a fabricated
///   empty assistant message;
/// - message parts are the only source of which tool activity exists, so nothing renders
///   twice;
/// - a payload the projection cannot read is skipped or emptied, never invented and never
///   a crash. That last one matters most: the projection has no failure path at all, and
///   these are the cases that would otherwise become one.
@Suite("Conversation timeline projection")
struct ConversationTimelineProjectionTests {

    // MARK: - Input

    private func input(
        runs: [AgentRunRecord],
        messages: [MessageRecord] = [],
        parts: [MessagePartRecord] = [],
        toolCalls toolCallRecords: [ToolCallRecord] = [],
        toolResults: [ToolResultRecord] = []
    ) -> ConversationTimelineInput {
        ConversationTimelineInput(
            conversationID: "c1",
            runs: runs,
            messagesByID: Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) }),
            partsByMessageID: Dictionary(grouping: parts, by: \.messageID),
            toolCallsByID: Dictionary(uniqueKeysWithValues: toolCallRecords.map { ($0.id, $0) }),
            toolResultsByToolCallID: Dictionary(uniqueKeysWithValues: toolResults.map { ($0.toolCallID, $0) })
        )
    }

    /// A part with an exotic payload.
    ///
    /// `Fixtures.textPart` builds the one payload shape a text part has; the tool cases
    /// below are about the payload itself — a valid one, a malformed one, one naming a call
    /// that does not exist — so they state it directly.
    private func part(
        _ id: String,
        of messageID: String,
        sequence: Int,
        kind: MessagePartKind,
        payload: String
    ) -> MessagePartRecord {
        MessagePartRecord(
            id: id,
            messageID: messageID,
            sequence: sequence,
            kind: kind,
            state: .completed,
            payload: payload
        )
    }

    /// A user message and an assistant message, each with one text part.
    private func twoMessageConversation(
        prompt: String = "prompt",
        answer: String = "answer"
    ) -> (messages: [MessageRecord], parts: [MessagePartRecord]) {
        (
            [
                Fixtures.message(id: "m1", role: .user),
                Fixtures.message(id: "m2", role: .assistant, sequence: 1),
            ],
            [
                Fixtures.textPart(id: "m1-p0", messageID: "m1", text: prompt),
                Fixtures.textPart(id: "m2-p0", messageID: "m2", text: answer),
            ]
        )
    }

    // MARK: - Reading items out of a projection

    private func assistantTexts(_ items: [TimelineItem]) -> [String] {
        items.compactMap { if case .assistantText(let text) = $0 { return text } else { return nil } }
    }

    private func toolCalls(_ items: [TimelineItem]) -> [ToolCallPresentation] {
        items.compactMap { if case .toolCall(let call) = $0 { return call } else { return nil } }
    }

    private func runNotices(_ items: [TimelineItem]) -> [RunNoticePresentation] {
        items.compactMap { if case .runNotice(let notice) = $0 { return notice } else { return nil } }
    }

    // MARK: - Turns

    @Test("no runs, no turns")
    func emptyInputMakesNoTurns() {
        let projection = ConversationTimelineProjection.build(from: input(runs: []))

        #expect(projection.turns.isEmpty, "a conversation with no runs must not render an empty turn")
        #expect(projection.conversationID == "c1")
    }

    @Test("a parent run with a trigger and a response is one turn, in that order")
    func oneParentRunIsOneTurn() {
        let conversation = twoMessageConversation()
        let run = Fixtures.run(
            id: "r1",
            state: .completed,
            triggerMessageID: "m1",
            responseMessageID: "m2"
        )

        let projection = ConversationTimelineProjection.build(from: input(
            runs: [run],
            messages: conversation.messages,
            parts: conversation.parts
        ))

        #expect(projection.turns.count == 1)
        #expect(
            projection.turns.first?.items == [.userText("prompt"), .assistantText("answer")],
            "a turn reads as the user's message then the assistant's, in that order"
        )
        #expect(
            projection.turns.first?.id == "r1",
            "the turn's identity is the run's id — a turn is the run"
        )
    }

    @Test("turns follow the runs' createdAt, not the order they were passed in")
    func turnsAreOrderedByCreation() {
        let conversation = twoMessageConversation()
        let earlier = Fixtures.run(
            id: "r1", state: .completed, triggerMessageID: "m1", createdAt: Fixtures.epoch
        )
        let later = Fixtures.run(
            id: "r2",
            state: .completed,
            triggerMessageID: "m1",
            createdAt: Fixtures.epoch.addingTimeInterval(60)
        )

        // Handed over newest-first on purpose: the order must come from the projection.
        let projection = ConversationTimelineProjection.build(from: input(
            runs: [later, earlier],
            messages: conversation.messages,
            parts: conversation.parts
        ))

        #expect(
            projection.turns.map(\.runID) == ["r1", "r2"],
            "the reading order is the runs' own order, not the order the caller happened to read them"
        )
    }

    @Test("two runs created in the same instant are ordered by id")
    func sameInstantTurnsAreOrderedByID() {
        let conversation = twoMessageConversation()
        // Same `createdAt`, deliberately. Without the id tie-break in the sort these two
        // have no defined order, and the same conversation would render differently
        // between launches.
        let second = Fixtures.run(
            id: "rb", state: .completed, triggerMessageID: "m1", createdAt: Fixtures.epoch
        )
        let first = Fixtures.run(
            id: "ra", state: .completed, triggerMessageID: "m1", createdAt: Fixtures.epoch
        )

        let projection = ConversationTimelineProjection.build(from: input(
            runs: [second, first],
            messages: conversation.messages,
            parts: conversation.parts
        ))

        #expect(projection.turns.map(\.runID) == ["ra", "rb"])
    }

    @Test("a child run is not a turn")
    func childRunsMakeNoTurns() {
        let conversation = twoMessageConversation()
        let parent = Fixtures.run(
            id: "r1", state: .completed, triggerMessageID: "m1", responseMessageID: "m2"
        )
        let child = Fixtures.run(
            id: "r-child", kind: .child, state: .completed, parentRunID: "r1", triggerMessageID: "m1"
        )

        let projection = ConversationTimelineProjection.build(from: input(
            runs: [parent, child],
            messages: conversation.messages,
            parts: conversation.parts
        ))

        #expect(
            projection.turns.map(\.runID) == ["r1"],
            "a subagent run is not a turn; only the parent run the user sent is"
        )
    }

    // MARK: - A run with no assistant message

    @Test("a run that failed before producing anything gets a notice, not an empty message")
    func failedRunGetsANotice() {
        let conversation = twoMessageConversation()
        let run = Fixtures.run(
            id: "r1",
            state: .failed,
            endReason: .providerFailed,
            triggerMessageID: "m1"
        )

        let projection = ConversationTimelineProjection.build(from: input(
            runs: [run],
            messages: conversation.messages,
            parts: conversation.parts
        ))

        let items = projection.turns.first?.items ?? []
        #expect(
            items == [
                .userText("prompt"),
                .runNotice(RunNoticePresentation(runID: "r1", state: .failed, endReason: .providerFailed)),
            ],
            "the failure is anchored on the user message it belongs to, as the run's own state"
        )
        #expect(
            assistantTexts(items).isEmpty,
            "a provider that failed before producing anything must not get a placeholder assistant message"
        )
    }

    @Test("a cancelled run gets a notice, not an empty message")
    func cancelledRunGetsANotice() {
        let conversation = twoMessageConversation()
        let run = Fixtures.run(
            id: "r1",
            state: .cancelled,
            endReason: .cancelledByUser,
            triggerMessageID: "m1"
        )

        let projection = ConversationTimelineProjection.build(from: input(
            runs: [run],
            messages: conversation.messages,
            parts: conversation.parts
        ))

        let items = projection.turns.first?.items ?? []
        #expect(runNotices(items) == [RunNoticePresentation(
            runID: "r1", state: .cancelled, endReason: .cancelledByUser
        )])
        #expect(assistantTexts(items).isEmpty, "cancelling must not leave an assistant message behind")
    }

    @Test("a run still streaming shows its state")
    func streamingRunGetsANotice() {
        let conversation = twoMessageConversation()
        let run = Fixtures.run(id: "r1", state: .streaming, triggerMessageID: "m1")

        let projection = ConversationTimelineProjection.build(from: input(
            runs: [run],
            messages: conversation.messages,
            parts: conversation.parts
        ))

        let notices = runNotices(projection.turns.first?.items ?? [])
        #expect(notices.count == 1)
        #expect(notices.first?.state == .streaming)
        #expect(notices.first?.endReason == nil, "a run that has not ended has no end reason to show")
    }

    // MARK: - Tool activity

    @Test("tool activity appears once, in part order, with its state from the record")
    func toolActivityFollowsPartOrderWithoutDuplicating() {
        let conversation = twoMessageConversation()
        let run = Fixtures.run(
            id: "r1",
            state: .completed,
            triggerMessageID: "m1",
            responseMessageID: "m2"
        )
        let parts = [
            Fixtures.textPart(id: "m1-p0", messageID: "m1", text: "prompt"),
            Fixtures.textPart(id: "m2-p0", messageID: "m2", sequence: 0, text: "before"),
            part("m2-p1", of: "m2", sequence: 1, kind: .toolCall, payload: #"{"toolCallID":"tc1"}"#),
            part("m2-p2", of: "m2", sequence: 2, kind: .toolResult, payload: #"{"toolCallID":"tc1"}"#),
            Fixtures.textPart(id: "m2-p3", messageID: "m2", sequence: 3, text: "after"),
        ]

        let projection = ConversationTimelineProjection.build(from: input(
            runs: [run],
            messages: conversation.messages,
            parts: parts,
            toolCalls: [Fixtures.toolCall(id: "tc1", runID: "r1", action: "files.write", state: .succeeded)],
            toolResults: [ToolResultRecord(toolCallID: "tc1", payload: #"{"ok":true}"#, createdAt: Fixtures.epoch)]
        ))

        let items = projection.turns.first?.items ?? []
        #expect(items == [
            .userText("prompt"),
            .assistantText("before"),
            .toolCall(ToolCallPresentation(toolCallID: "tc1", action: "files.write", state: .succeeded)),
            .toolResult(ToolResultPresentation(toolCallID: "tc1", payload: #"{"ok":true}"#)),
            .assistantText("after"),
        ])
        #expect(
            toolCalls(items).count == 1,
            "the part is where the call appears; the run's call rows must not add a second copy of it"
        )
    }

    @Test("tool activity the message does not contain is not added")
    func undeclaredToolCallsAreNotAppended() {
        let conversation = twoMessageConversation()
        let run = Fixtures.run(
            id: "r1",
            state: .completed,
            triggerMessageID: "m1",
            responseMessageID: "m2"
        )
        let parts = [
            Fixtures.textPart(id: "m1-p0", messageID: "m1", text: "prompt"),
            part("m2-p0", of: "m2", sequence: 0, kind: .toolCall, payload: #"{"toolCallID":"tc1"}"#),
        ]

        let projection = ConversationTimelineProjection.build(from: input(
            runs: [run],
            messages: conversation.messages,
            parts: parts,
            // Two calls exist for the run; only one of them is in the message.
            toolCalls: [
                Fixtures.toolCall(id: "tc1", runID: "r1"),
                Fixtures.toolCall(id: "tc2", runID: "r1"),
            ]
        ))

        #expect(
            toolCalls(projection.turns.first?.items ?? []).map(\.toolCallID) == ["tc1"],
            "parts decide which calls exist; the run's other call must not be appended behind its back"
        )
    }

    // MARK: - Payloads the projection cannot read

    @Test("an unreadable text payload renders as empty text, and unreadable tool items are skipped")
    func undecodablePayloadsDoNotInventContent() {
        let conversation = twoMessageConversation()
        let run = Fixtures.run(
            id: "r1",
            state: .completed,
            triggerMessageID: "m1",
            responseMessageID: "m2"
        )
        let parts = [
            // A text part whose payload is not JSON at all. The item still exists — the
            // message did contain text — it just has nothing readable in it.
            part("m1-p0", of: "m1", sequence: 0, kind: .text, payload: "not json"),
            Fixtures.textPart(id: "m2-p0", messageID: "m2", sequence: 0, text: "answer"),
            part("m2-p1", of: "m2", sequence: 1, kind: .toolCall, payload: "not json"),
            // Valid JSON, but naming a call the input does not have.
            part("m2-p2", of: "m2", sequence: 2, kind: .toolCall, payload: #"{"toolCallID":"tc-absent"}"#),
            part("m2-p3", of: "m2", sequence: 3, kind: .toolResult, payload: "not json"),
            Fixtures.textPart(id: "m2-p4", messageID: "m2", sequence: 4, text: "tail"),
        ]

        let projection = ConversationTimelineProjection.build(from: input(
            runs: [run],
            messages: conversation.messages,
            parts: parts
        ))

        #expect(
            projection.turns.first?.items == [
                .userText(""),
                .assistantText("answer"),
                .assistantText("tail"),
            ],
            """
            a text payload we cannot read becomes empty text — the message did contain text, and \
            dropping the item would silently rewrite the conversation. Tool activity cannot be \
            shown without knowing what it was, so those items are skipped, and the readable \
            ones keep their order.
            """
        )
    }

    // MARK: - Missing messages

    @Test("a trigger id pointing at no message leaves the turn standing")
    func missingTriggerMessageIsSurvivable() {
        let conversation = twoMessageConversation()
        let run = Fixtures.run(
            id: "r1",
            state: .completed,
            triggerMessageID: "m-absent",
            responseMessageID: "m2"
        )

        let projection = ConversationTimelineProjection.build(from: input(
            runs: [run],
            messages: conversation.messages,
            parts: conversation.parts
        ))

        #expect(projection.turns.count == 1, "the run exists, so the turn exists")
        #expect(projection.turns.first?.items == [.assistantText("answer")])
    }

    @Test("a response id pointing at no message stays silent rather than inventing a notice")
    func missingResponseMessageIsSurvivable() {
        let conversation = twoMessageConversation()
        // The run says it produced a response; the message is not in the read set. This is
        // the one path where a turn can legitimately be short. What it must NOT do is treat
        // "bound but unreadable" as "never produced" and announce a failure — that would
        // turn a read problem into a claim about what the provider did.
        let run = Fixtures.run(
            id: "r1",
            state: .completed,
            triggerMessageID: "m1",
            responseMessageID: "m-absent"
        )

        let projection = ConversationTimelineProjection.build(from: input(
            runs: [run],
            messages: conversation.messages,
            parts: conversation.parts
        ))

        let items = projection.turns.first?.items ?? []
        #expect(projection.turns.count == 1)
        #expect(items == [.userText("prompt")])
        #expect(
            assistantTexts(items).isEmpty && runNotices(items).isEmpty,
            "neither a fabricated assistant message nor a run notice: the run did produce a response"
        )
    }

    // MARK: - Scale

    @Test("a thousand runs make a thousand turns, in order")
    func manyRunsStayInOrder() {
        let runCount = 1_000
        var runs: [AgentRunRecord] = []
        var messages: [MessageRecord] = []
        var parts: [MessagePartRecord] = []

        for index in 0..<runCount {
            let runID = "r\(index)"
            let messageID = "m\(index)"
            runs.append(Fixtures.run(
                id: runID,
                state: .completed,
                triggerMessageID: messageID,
                createdAt: Fixtures.epoch.addingTimeInterval(Double(index))
            ))
            messages.append(Fixtures.message(id: messageID, sequence: index))
            parts.append(Fixtures.textPart(id: "\(messageID)-p0", messageID: messageID))
        }

        let projection = ConversationTimelineProjection.build(from: input(
            runs: runs,
            messages: messages,
            parts: parts
        ))

        #expect(projection.turns.count == runCount)
        #expect(
            projection.turns.map(\.runID) == runs.map(\.id),
            "a long conversation keeps the order the runs were created in"
        )
        #expect(projection.turns.allSatisfy { $0.items == [.userText("hello")] })
    }
}

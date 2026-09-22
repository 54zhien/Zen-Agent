import Foundation

// The conversation timeline, as plain values.
//
// This file is deliberately narrow. It imports no UI framework, so the whole projection
// is a value a test can assert on without a screen, a render pass or a running app. It
// imports no storage engine either, and no `PersistenceStore` instance ever reaches these
// types: the input is plain values, so nothing here can read a row mid-render and the
// ordering rule stays in one place. The one thing borrowed from the store is
// `decodeTextPayload` — a pure JSON decoder with no database behind it.
//
// What a Turn is (the Blueprint's rule, not this file's invention):
//
//   - one UI Turn corresponds to exactly one `kind == .parent` run; child runs are not
//     Turns;
//   - the Turn's id **is** the run's id, and its content comes from the run's
//     `triggerMessageID` (the user message) and `responseMessageID` (the assistant
//     message);
//   - a run that produced no assistant message — it failed before the provider emitted
//     anything, or it is still going — **does not get an empty assistant message
//     fabricated for it**. The run's own state is that Turn's content, anchored after
//     the user message it belongs to. That is why `.runNotice` is a case rather than
//     the view being handed a blank assistant item to render.

/// Everything the projection needs, already read out of the store. A plain value type so the
/// projection itself is a pure function — no database, no clock, no ordering surprise.
struct ConversationTimelineInput: Sendable {
    let conversationID: String
    let runs: [AgentRunRecord]
    let messagesByID: [String: MessageRecord]
    let partsByMessageID: [String: [MessagePartRecord]]
    let toolCallsByID: [String: ToolCallRecord]
    let toolResultsByToolCallID: [String: ToolResultRecord]
}

/// A tool call, reduced to what the reading layout shows.
///
/// `action` and `state` are copied off the `ToolCallRecord` rather than off the message
/// part: the part carries an identity and nothing else, by design, so that execution
/// state has one truth instead of two that can drift.
struct ToolCallPresentation: Equatable, Sendable {
    let toolCallID: String
    let action: String
    let state: ToolCallState
}

/// A tool result, reduced to the body the reading layout shows.
struct ToolResultPresentation: Equatable, Sendable {
    let toolCallID: String
    let payload: String
}

/// A run that produced no assistant message. Covers both a run that failed before producing
/// anything and a run that is still going: identical presentation, different `state`.
struct RunNoticePresentation: Equatable, Sendable {
    let runID: String
    let state: RunState
    let endReason: EndReason?
}

/// One line of a Turn, in reading order.
enum TimelineItem: Equatable, Sendable {
    case userText(String)
    case assistantText(String)
    case reasoning(String)
    case toolCall(ToolCallPresentation)
    case toolResult(ToolResultPresentation)
    case runNotice(RunNoticePresentation)
}

/// One Turn: one parent run and everything that run put on screen.
struct ConversationTurn: Identifiable, Equatable, Sendable {
    let runID: String
    let items: [TimelineItem]

    var id: String { runID }
}

struct ConversationTimelineProjection: Equatable, Sendable {
    let conversationID: String
    let turns: [ConversationTurn]
}

extension ConversationTimelineProjection {

    /// Turns a read-out conversation into turns, in reading order.
    ///
    /// Pure and total: no clock, no I/O, no failure path. Anything that can throw
    /// (database access, decoding of stored payloads) has already happened in
    /// `ConversationTimelineLoader` or is absorbed per item below.
    static func build(from input: ConversationTimelineInput) -> ConversationTimelineProjection {
        // Only parent runs are turns. The stable tie-break matters: the whole rendered order
        // comes from here.
        let parentRuns = input.runs
            .filter { $0.kind == .parent }
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }

        let turns = parentRuns.map { run -> ConversationTurn in
            var items: [TimelineItem] = []

            if let triggerID = run.triggerMessageID {
                items.append(contentsOf: itemize(messageID: triggerID, input: input))
            }

            if let responseID = run.responseMessageID {
                items.append(contentsOf: itemize(messageID: responseID, input: input))
            } else {
                // No assistant message. Do NOT fabricate one: the run's own state is the
                // content for this turn, anchored after the user message it belongs to.
                items.append(.runNotice(RunNoticePresentation(
                    runID: run.id,
                    state: run.state,
                    endReason: run.endReason
                )))
            }

            return ConversationTurn(runID: run.id, items: items)
        }

        return ConversationTimelineProjection(conversationID: input.conversationID, turns: turns)
    }

    /// One message's parts, in `sequence` order — the parts ARE the timeline order for a message,
    /// so nothing is re-sorted here.
    ///
    /// The parts are also the only source of *which* tool activity exists. The run's tool
    /// call rows are consulted to fill in what a part already says is there, never to add
    /// an item the message does not contain — otherwise every call would render twice.
    private static func itemize(messageID: String, input: ConversationTimelineInput) -> [TimelineItem] {
        guard let message = input.messagesByID[messageID] else { return [] }
        let parts = input.partsByMessageID[messageID] ?? []

        return parts.compactMap { part -> TimelineItem? in
            switch part.kind {
            case .text:
                let text = (try? PersistenceStore.decodeTextPayload(part.payload).text) ?? ""
                return message.role == .user ? .userText(text) : .assistantText(text)

            case .reasoning:
                let text = (try? PersistenceStore.decodeTextPayload(part.payload).text) ?? ""
                return .reasoning(text)

            case .toolCall:
                guard let payload = try? JSONDecoder().decode(ToolCallPartPayload.self, from: Data(part.payload.utf8)),
                      let call = input.toolCallsByID[payload.toolCallID]
                else { return nil }   // no invented activity from a payload we cannot read
                return .toolCall(ToolCallPresentation(toolCallID: call.id, action: call.action, state: call.state))

            case .toolResult:
                guard let payload = try? JSONDecoder().decode(ToolResultPartPayload.self, from: Data(part.payload.utf8)),
                      let result = input.toolResultsByToolCallID[payload.toolCallID]
                else { return nil }
                return .toolResult(ToolResultPresentation(toolCallID: result.toolCallID, payload: result.payload))
            }
        }
    }
}

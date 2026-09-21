import Foundation

enum AgentEvent: Sendable, Equatable {
    case runAccepted(runID: String, conversationID: String)
    case runStateChanged(runID: String, state: RunState)
    case messagePartStarted(
        runID: String,
        messageID: String,
        partID: String,
        kind: MessagePartKind
    )
    case messagePartDelta(
        runID: String,
        partID: String,
        delta: String
    )
    case messagePartCompleted(
        runID: String,
        partID: String,
        state: MessagePartState
    )
    case toolCallChanged(
        runID: String,
        toolCallID: String,
        state: ToolCallState
    )
    case approvalRequired(
        runID: String,
        toolCallID: String
    )
    case runEnded(
        runID: String,
        state: RunState,
        endReason: EndReason
    )
}

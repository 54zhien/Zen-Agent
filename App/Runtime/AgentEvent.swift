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
        delta: String,
        endUTF8Offset: Int
    )
    case messagePartCompleted(
        runID: String,
        partID: String,
        state: MessagePartState
    )
    case toolCallChanged(
        runID: String,
        providerCallID: String,
        state: ToolCallState
    )
    /// Carries the durable ToolCallRecord.id consumed by approve/reject.
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

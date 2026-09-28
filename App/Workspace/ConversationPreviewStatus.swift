import Foundation

enum ConversationCardStatus: String, Equatable, Sendable {
    case generating, reasoningVisible, tool, approval, cancelled, failed, authenticationRequired

    static func derive(from projection: RunProjection?, visibleReasoningAllowed: Bool = false) -> Self? {
        guard let projection else { return nil }
        switch projection.state {
        case .completed: return nil
        case .cancelled: return projection.endReason == .cancelledByUser ? .cancelled : .failed
        case .failed: return projection.endReason == .credentialExpired ? .authenticationRequired : .failed
        case .waitingForApproval: return .approval
        case .toolRequested, .executingTools: return .tool
        case .streaming: return visibleReasoningAllowed ? .reasoningVisible : .generating
        case .preparing, .requestingModel, .continuing, .stopping, .suspended, .recovering:
            return .generating
        }
    }
}

/// Content readiness is separate from the Run's business status on its Card.
enum ConversationPreviewStatus: Equatable, Sendable {
    case ready
    case contentUnavailable
    case restoring
    case migrationRequired
    case failed(String)
}

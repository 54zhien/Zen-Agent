import Foundation

enum ToolApprovalDecision: CaseIterable, Hashable, Sendable, Identifiable {
    case approveOnce
    case rejectOnce

    var id: Self { self }

    var title: String {
        switch self {
        case .approveOnce: "批准本次"
        case .rejectOnce: "拒绝本次"
        }
    }
}

struct ToolApprovalRequest: Sendable, Equatable {
    let toolCallID: String
    let conversationID: String
    let runtimeInstanceID: String
    let decision: ToolApprovalDecision

    fileprivate init(
        toolCallID: String,
        conversationID: String,
        runtimeInstanceID: String,
        decision: ToolApprovalDecision
    ) {
        self.toolCallID = toolCallID
        self.conversationID = conversationID
        self.runtimeInstanceID = runtimeInstanceID
        self.decision = decision
    }
}

/// The read-only approval card data projected from a persisted execution intent.
struct ToolApprovalProjection: Identifiable, Sendable, Equatable {
    let toolCallID: String
    let conversationID: String
    let runtimeInstanceID: String
    let toolDisplayName: String
    let action: String
    let targetDescription: String
    let keyImpact: String

    var id: String { toolCallID }
    var availableDecisions: [ToolApprovalDecision] { ToolApprovalDecision.allCases }

    init(
        toolCallID: String,
        conversationID: String,
        runtimeInstanceID: String,
        disclosure: ToolApprovalDisclosure
    ) {
        self.toolCallID = toolCallID
        self.conversationID = conversationID
        self.runtimeInstanceID = runtimeInstanceID
        self.toolDisplayName = disclosure.toolDisplayName
        self.action = disclosure.action
        self.targetDescription = disclosure.targetDescription
        self.keyImpact = disclosure.keyImpact
    }

    func request(for decision: ToolApprovalDecision) -> ToolApprovalRequest {
        ToolApprovalRequest(
            toolCallID: toolCallID,
            conversationID: conversationID,
            runtimeInstanceID: runtimeInstanceID,
            decision: decision
        )
    }
}

enum ToolApprovalResolutionError: Error, Equatable, Sendable {
    case staleRuntimeInstance
    case toolCallNotFound(String)
    case runNotFound(String)
    case conversationMismatch
    case notParentCall
    case callNotWaitingForApproval(String)
}

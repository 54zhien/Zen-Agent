import Foundation

enum ToolApprovalDecision: CaseIterable, Hashable, Sendable, Identifiable {
    case approveOnce
    case approveConversation
    case rejectOnce
    case requestSystemPermission
    case declineSystemPermission

    var id: Self { self }

    var title: String {
        switch self {
        case .approveOnce: "批准本次"
        case .approveConversation: "允许本会话"
        case .rejectOnce: "拒绝本次"
        case .requestSystemPermission: "请求系统权限"
        case .declineSystemPermission: "暂不请求"
        }
    }
}

enum ToolApprovalKind: Sendable, Equatable { case tool, systemPermission }

struct ToolApprovalRequest: Sendable, Equatable {
    let toolCallID: String
    let conversationID: String
    let runtimeInstanceID: String
    let decision: ToolApprovalDecision
    let intentBinding: String?

    fileprivate init(
        toolCallID: String,
        conversationID: String,
        runtimeInstanceID: String,
        decision: ToolApprovalDecision,
        intentBinding: String?
    ) {
        self.toolCallID = toolCallID
        self.conversationID = conversationID
        self.runtimeInstanceID = runtimeInstanceID
        self.decision = decision
        self.intentBinding = intentBinding
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
    let intentBinding: String?

    var id: String { toolCallID }
    let kind: ToolApprovalKind
    let allowsConversationGrant: Bool
    let systemPermissionDescription: String?
    let systemPermissionPhase: ToolSystemConsentPhase?

    var availableDecisions: [ToolApprovalDecision] {
        switch kind {
        case .tool:
            allowsConversationGrant ? [.approveOnce, .approveConversation, .rejectOnce] : [.approveOnce, .rejectOnce]
        case .systemPermission:
            systemPermissionPhase == .waiting ? [.requestSystemPermission, .declineSystemPermission] : []
        }
    }

    var scopeDescription: String {
        if kind == .systemPermission { return "仅请求 iOS 系统权限，不产生工具授权。" }
        return allowsConversationGrant ? "本次调用，或本会话内相同动作、资源版本和目标。" : "仅本次调用"
    }

    init(
        toolCallID: String,
        conversationID: String,
        runtimeInstanceID: String,
        disclosure: ToolApprovalDisclosure,
        intentBinding: String? = nil,
        kind: ToolApprovalKind = .tool,
        allowsConversationGrant: Bool = false,
        systemPermissionDescription: String? = nil,
        systemPermissionPhase: ToolSystemConsentPhase? = nil
    ) {
        self.toolCallID = toolCallID
        self.conversationID = conversationID
        self.runtimeInstanceID = runtimeInstanceID
        self.toolDisplayName = disclosure.toolDisplayName
        self.action = disclosure.action
        self.targetDescription = disclosure.targetDescription
        self.keyImpact = disclosure.keyImpact
        self.intentBinding = intentBinding
        self.kind = kind; self.allowsConversationGrant = allowsConversationGrant
        self.systemPermissionDescription = systemPermissionDescription
        self.systemPermissionPhase = systemPermissionPhase
    }

    func request(for decision: ToolApprovalDecision) -> ToolApprovalRequest {
        ToolApprovalRequest(
            toolCallID: toolCallID,
            conversationID: conversationID,
            runtimeInstanceID: runtimeInstanceID,
            decision: decision,
            intentBinding: intentBinding
        )
    }
}

enum ToolApprovalResolutionError: Error, Equatable, Sendable {
    case staleRuntimeInstance
    case staleIntent
    case toolCallNotFound(String)
    case runNotFound(String)
    case conversationMismatch
    case notParentCall
    case callNotWaitingForApproval(String)
}

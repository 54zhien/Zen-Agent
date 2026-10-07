/// Trusted identity projections from the existing Runtime and frozen intent.
/// These values carry no arguments, executable payload or ToolCall state.
enum ToolGrantSubject: Sendable, Equatable {
    case parentConversation(String)
    case run(String)

    var isValid: Bool {
        switch self {
        case .parentConversation(let id), .run(let id): !id.isEmpty
        }
    }
}

enum ToolResourceScope: Sendable, Equatable {
    case notRequired
    case missing
    case target(String)
    case file(assetID: String, versionID: String, contentIdentity: String)

    var isValid: Bool {
        switch self {
        case .notRequired: true
        case .missing: false
        case .target(let id): !id.isEmpty
        case .file(let asset, let version, let content):
            !asset.isEmpty && !version.isEmpty && !content.isEmpty
        }
    }
}

enum ToolDestinationScope: Sendable, Equatable {
    case notRequired
    case missing
    case provider(instanceID: String, endpointIdentity: String)

    var isValid: Bool {
        switch self {
        case .notRequired: true
        case .missing: false
        case .provider(let instance, let endpoint):
            !instance.isEmpty && !endpoint.isEmpty
        }
    }
}

struct ToolPolicyCallContext: Sendable, Equatable {
    let toolCallID: String
    let agentRunID: String
    let subject: ToolGrantSubject
    let toolID: String
    let actionID: String
    let descriptorRevision: String
    /// Binding to the entire existing immutable intent, supplied by trusted code.
    let intentBinding: String
    let resource: ToolResourceScope
    let destination: ToolDestinationScope

    var hasValidIdentity: Bool {
        guard !toolCallID.isEmpty, !agentRunID.isEmpty, subject.isValid,
              !toolID.isEmpty, !actionID.isEmpty, !descriptorRevision.isEmpty,
              !intentBinding.isEmpty else { return false }
        if case .run(let id) = subject { return id == agentRunID }
        return true
    }
}

enum ToolGrantKind: Sendable, Equatable {
    case once(toolCallID: String, agentRunID: String, intentBinding: String)
    case conversation
}

enum ToolGrantValidity: Sendable, Equatable {
    case active
    case revoked
    case consumed
}

struct ToolScopedGrant: Sendable, Equatable {
    let kind: ToolGrantKind
    let subject: ToolGrantSubject
    let toolID: String
    let actionID: String
    let descriptorRevision: String
    let resource: ToolResourceScope
    let destination: ToolDestinationScope
    let validity: ToolGrantValidity
}

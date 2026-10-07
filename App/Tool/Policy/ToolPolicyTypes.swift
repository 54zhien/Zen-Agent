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
    /// Projections of existing call/subject eligibility, not an execution state.
    let authorizationIsAvailable: Bool
    let subjectIsAvailable: Bool

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
    let revocationEpoch: UInt64
    /// A conversation grant can authorize future calls without matching this
    /// origin; an already waiting call needs its own explicit approval witness.
    let issuedFor: ToolGrantApprovalBinding?
}

struct ToolGrantApprovalBinding: Sendable, Equatable {
    let toolCallID: String
    let agentRunID: String
    let intentBinding: String
}

enum ToolActionRisk: Sendable, Equatable {
    case low, high, destructive, unknown
}

enum ToolPolicyResourceRequirement: Sendable, Equatable {
    case notRequired, target, file, unknown

    func accepts(_ scope: ToolResourceScope) -> Bool {
        guard scope.isValid else { return false }
        return switch (self, scope) {
        case (.notRequired, .notRequired), (.target, .target), (.file, .file): true
        default: false
        }
    }
}

enum ToolPolicyEgressRequirement: Sendable, Equatable {
    case notRequired, provider, providerRequiringApproval, unknown

    func accepts(_ scope: ToolDestinationScope) -> Bool {
        guard scope.isValid else { return false }
        return switch (self, scope) {
        case (.notRequired, .notRequired), (.provider, .provider),
             (.providerRequiringApproval, .provider): true
        default: false
        }
    }
}

struct ToolPolicyActionMetadata: Sendable, Equatable {
    let toolID: String
    let actionID: String
    let descriptorRevision: String
    let risk: ToolActionRisk
    let allowsAutomaticApproval: Bool
    let allowsConversationGrant: Bool
    let resourceRequirement: ToolPolicyResourceRequirement
    let egressRequirement: ToolPolicyEgressRequirement

    var isKnown: Bool {
        risk != .unknown && resourceRequirement != .unknown && egressRequirement != .unknown
    }

    var requiresExplicitApproval: Bool {
        risk != .low || egressRequirement == .providerRequiringApproval
    }
}

enum ToolPersistentPolicy: Sendable, Equatable {
    case alwaysAllow, askEveryTime, deny
}

enum ToolPolicySafetyCap: Sendable, Equatable {
    case unrestricted, requiresExplicitApproval, deny, unknown
}

struct ToolPolicySnapshot: Sendable, Equatable {
    let toolID: String
    let actionID: String
    let descriptorRevision: String
    let mode: ToolPersistentPolicy
    /// Monotonic relevant-authority revocation floor supplied by trusted code.
    /// It advances on relevant policy/cap/grant tightening, never on widening.
    let revocationEpoch: UInt64

    func bindsLogicalAction(_ call: ToolPolicyCallContext) -> Bool {
        toolID == call.toolID && actionID == call.actionID
    }

    func binds(_ call: ToolPolicyCallContext) -> Bool {
        bindsLogicalAction(call) && descriptorRevision == call.descriptorRevision
    }
}

enum ToolPolicyAdmissionDisposition: Sendable, Equatable {
    case allowed, needsApproval, denied
}

/// Authorization at preparation, not a second execution state. Repreparing the
/// same call must not transfer this admission to a different frozen intent.
struct ToolPolicyAdmission: Sendable, Equatable {
    let disposition: ToolPolicyAdmissionDisposition
    let intentBinding: String
}

struct ToolPolicyEvaluationInput: Sendable, Equatable {
    let action: ToolPolicyActionMetadata?
    let safetyCap: ToolPolicySafetyCap
    let policyAtCreation: ToolPolicySnapshot
    let admission: ToolPolicyAdmission
    let currentPolicy: ToolPolicySnapshot
    let call: ToolPolicyCallContext
    /// Current trusted resolution, compared with the existing frozen intent.
    /// It contains neither executable arguments nor an alternative ToolCall.
    let resolvedResource: ToolResourceScope
    let resolvedDestination: ToolDestinationScope
    let resolvedIntentBinding: String
    let grants: [ToolScopedGrant]
}

enum ToolPolicyReason: Sendable, Equatable {
    case globalPolicy, onceGrant, conversationGrant
    case hardDeny, globalDeny, unknownSafetyCap, unknownMetadata
    case explicitApprovalRequired, automaticApprovalForbidden
    case noApplicableGrant, conversationGrantForbidden
    case invalidIdentity, actionChanged, descriptorChanged, policyChanged
    case invalidResourceScope, invalidDestinationScope
    case resourceChanged, destinationChanged, intentChanged
    case priorApprovalRequired, authorizationUnavailable, subjectUnavailable
    case stalePolicySnapshot
}

enum ToolPolicyDecision: Sendable, Equatable {
    case allow(ToolPolicyReason)
    case needsApproval(ToolPolicyReason)
    case deny(ToolPolicyReason)
    case dependencyChanged(ToolPolicyReason)
}

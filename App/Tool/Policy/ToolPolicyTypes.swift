/// Trusted identity projections from the existing Runtime and frozen intent.
/// These values carry no arguments, executable payload or ToolCall state.
enum ToolPolicyIdentity {
    static func isValid(_ value: String) -> Bool {
        value.contains { !$0.isWhitespace }
    }

    static func equals(_ lhs: String, _ rhs: String) -> Bool {
        // These are opaque resolved identities, not human text. String equality
        // would merge different Unicode encodings through canonical equivalence.
        lhs.utf8.elementsEqual(rhs.utf8)
    }
}

enum ToolGrantSubject: Sendable, Equatable {
    case parentConversation(String)
    case run(String)

    var isValid: Bool {
        switch self {
        case .parentConversation(let id), .run(let id): ToolPolicyIdentity.isValid(id)
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.parentConversation(let a), .parentConversation(let b)), (.run(let a), .run(let b)):
            ToolPolicyIdentity.equals(a, b)
        default: false
        }
    }
}

enum ToolResourceScope: Codable, Sendable, Equatable {
    case notRequired
    case missing
    case target(String)
    case file(assetID: String, versionID: String, contentIdentity: String)

    var isValid: Bool {
        switch self {
        case .notRequired: true
        case .missing: false
        case .target(let id): ToolPolicyIdentity.isValid(id)
        case .file(let asset, let version, let content):
            ToolPolicyIdentity.isValid(asset) && ToolPolicyIdentity.isValid(version) && ToolPolicyIdentity.isValid(content)
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.notRequired, .notRequired), (.missing, .missing): true
        case (.target(let a), .target(let b)): ToolPolicyIdentity.equals(a, b)
        case (.file(let a, let v, let c), .file(let b, let w, let d)):
            ToolPolicyIdentity.equals(a, b) && ToolPolicyIdentity.equals(v, w) && ToolPolicyIdentity.equals(c, d)
        default: false
        }
    }
}

enum ToolDestinationScope: Codable, Sendable, Equatable {
    case notRequired
    case missing
    case provider(instanceID: String, endpointIdentity: String)

    var isValid: Bool {
        switch self {
        case .notRequired: true
        case .missing: false
        case .provider(let instance, let endpoint):
            ToolPolicyIdentity.isValid(instance) && ToolPolicyIdentity.isValid(endpoint)
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.notRequired, .notRequired), (.missing, .missing): true
        case (.provider(let a, let e), .provider(let b, let f)):
            ToolPolicyIdentity.equals(a, b) && ToolPolicyIdentity.equals(e, f)
        default: false
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
        guard ToolPolicyIdentity.isValid(toolCallID), ToolPolicyIdentity.isValid(agentRunID), subject.isValid,
              ToolPolicyIdentity.isValid(toolID), ToolPolicyIdentity.isValid(actionID),
              ToolPolicyIdentity.isValid(descriptorRevision), ToolPolicyIdentity.isValid(intentBinding) else { return false }
        if case .run(let id) = subject { return ToolPolicyIdentity.equals(id, agentRunID) }
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

    func binds(_ call: ToolPolicyCallContext) -> Bool {
        ToolPolicyIdentity.equals(toolCallID, call.toolCallID)
            && ToolPolicyIdentity.equals(agentRunID, call.agentRunID)
            && ToolPolicyIdentity.equals(intentBinding, call.intentBinding)
    }
}

enum ToolActionRisk: Codable, Sendable, Equatable {
    case low, high, destructive, unknown
}

enum ToolPolicyResourceRequirement: Codable, Sendable, Equatable {
    case notRequired, target, file, unknown

    func accepts(_ scope: ToolResourceScope) -> Bool {
        guard scope.isValid else { return false }
        return switch (self, scope) {
        case (.notRequired, .notRequired), (.target, .target), (.file, .file): true
        default: false
        }
    }
}

enum ToolPolicyEgressRequirement: Codable, Sendable, Equatable {
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

struct ToolPolicyActionMetadata: Codable, Sendable, Equatable {
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
        ToolPolicyIdentity.equals(toolID, call.toolID) && ToolPolicyIdentity.equals(actionID, call.actionID)
    }

    func binds(_ call: ToolPolicyCallContext) -> Bool {
        bindsLogicalAction(call) && ToolPolicyIdentity.equals(descriptorRevision, call.descriptorRevision)
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

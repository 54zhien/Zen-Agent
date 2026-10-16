import Testing

@testable import ZenAgent

@Suite("Tool Policy effective permission")
struct ToolPolicyEvaluatorTests {
    static let ordinaryAction = ToolPolicyActionMetadata(
        toolID: "files", actionID: "read", descriptorRevision: "r1", risk: .low,
        allowsAutomaticApproval: true, allowsConversationGrant: true,
        resourceRequirement: .file, egressRequirement: .provider
    )

    @Test(arguments: [ToolGrantKind.once(toolCallID: "call", agentRunID: "run", intentBinding: "intent"), .conversation])
    func hardDenyOverridesOnceAndConversationGrants(kind: ToolGrantKind) {
        let grants = [ToolPolicyScopeTests().grant(kind: kind)]
        #expect(ToolPolicyEvaluator.evaluate(input(grants: grants)) == permitted(kind))
        #expect(ToolPolicyEvaluator.evaluate(input(cap: .deny, grants: grants)) == .deny(.hardDeny))
    }

    @Test(arguments: [ToolGrantKind.once(toolCallID: "call", agentRunID: "run", intentBinding: "intent"), .conversation])
    func globalDenyOverridesEveryGrant(kind: ToolGrantKind) {
        let grants = [ToolPolicyScopeTests().grant(kind: kind)]
        #expect(ToolPolicyEvaluator.evaluate(input(grants: grants)) == permitted(kind))
        #expect(ToolPolicyEvaluator.evaluate(input(mode: .deny, grants: grants)) == .deny(.globalDeny))
    }

    @Test func explicitApprovalCapBlocksAlwaysAllow() {
        #expect(ToolPolicyEvaluator.evaluate(input(mode: .alwaysAllow)) == .allow(.globalPolicy))
        #expect(ToolPolicyEvaluator.evaluate(input(cap: .requiresExplicitApproval, mode: .alwaysAllow)) == .needsApproval(.explicitApprovalRequired))
        let once = ToolPolicyScopeTests().grant(kind: .once(toolCallID: "call", agentRunID: "run", intentBinding: "intent"))
        #expect(ToolPolicyEvaluator.evaluate(input(cap: .requiresExplicitApproval, mode: .alwaysAllow, grants: [once])) == .allow(.onceGrant))
    }

    @Test func matchingOnceSatisfiesAskPolicy() {
        let once = ToolPolicyScopeTests().grant(kind: .once(toolCallID: "call", agentRunID: "run", intentBinding: "intent"))
        #expect(ToolPolicyEvaluator.evaluate(input(grants: [once])) == .allow(.onceGrant))
    }

    @Test func matchingConversationGrantIsScopeBounded() {
        let scope = ToolPolicyScopeTests()
        #expect(ToolPolicyEvaluator.evaluate(input(grants: [scope.grant()])) == .allow(.conversationGrant))
        #expect(ToolPolicyEvaluator.evaluate(input(call: scope.call(callID: "next", runID: "next-run", binding: "next-intent"), grants: [scope.grant()])) == .allow(.conversationGrant))
        #expect(ToolPolicyEvaluator.evaluate(input(grants: [scope.grant(subject: .parentConversation("other"))])) == .needsApproval(.noApplicableGrant))
    }

    @Test func destructiveActionCannotUseForbiddenGrantKind() {
        let action = metadata(risk: .destructive, allowsConversation: false)
        #expect(ToolPolicyEvaluator.evaluate(input(action: action, grants: [ToolPolicyScopeTests().grant()])) == .needsApproval(.conversationGrantForbidden))
        let once = ToolPolicyScopeTests().grant(kind: .once(toolCallID: "call", agentRunID: "run", intentBinding: "intent"))
        #expect(ToolPolicyEvaluator.evaluate(input(action: action, grants: [once])) == .allow(.onceGrant))
    }

    @Test func unknownMetadataDoesNotAllow() {
        #expect(ToolPolicyEvaluator.evaluate(input(action: nil, mode: .alwaysAllow)) == .deny(.unknownMetadata))
        for unknown in [metadata(risk: .unknown), metadata(resource: .unknown), metadata(egress: .unknown)] {
            #expect(ToolPolicyEvaluator.evaluate(input(action: unknown, mode: .alwaysAllow, grants: [ToolPolicyScopeTests().grant()])) == .deny(.unknownMetadata))
        }
    }

    @Test(arguments: [ToolPolicySafetyCap.unrestricted, .requiresExplicitApproval, .deny, .unknown])
    func capAlwaysAllowMatrix(cap: ToolPolicySafetyCap) {
        let expected: ToolPolicyDecision
        switch cap {
        case .unrestricted: expected = .allow(.globalPolicy)
        case .requiresExplicitApproval: expected = .needsApproval(.explicitApprovalRequired)
        case .deny: expected = .deny(.hardDeny)
        case .unknown: expected = .deny(.unknownSafetyCap)
        }
        #expect(ToolPolicyEvaluator.evaluate(input(cap: cap, mode: .alwaysAllow)) == expected)
    }

    @Test(arguments: [ToolResourceScope.file(assetID: "other", versionID: "version", contentIdentity: "digest"),
                      .file(assetID: "asset", versionID: "v2", contentIdentity: "digest"),
                      .file(assetID: "asset", versionID: "version", contentIdentity: "changed"), .notRequired, .missing])
    func askScopeMismatchHasNoIndependentPermission(resource: ToolResourceScope) {
        // Only the grant changes; this call has no independent automatic permission.
        #expect(ToolPolicyEvaluator.evaluate(input(grants: [ToolPolicyScopeTests().grant(resource: resource)])) == .needsApproval(.noApplicableGrant))
    }

    @Test(arguments: [ToolActionRisk.high, .destructive])
    func riskCannotBeOverriddenByAnAutomaticFlag(risk: ToolActionRisk) {
        #expect(ToolPolicyEvaluator.evaluate(input(action: metadata(risk: risk), mode: .alwaysAllow)) == .needsApproval(.explicitApprovalRequired))
    }

    @Test func descriptorCanForbidAutomaticApproval() {
        #expect(ToolPolicyEvaluator.evaluate(input(action: metadata(allowsAutomatic: false), mode: .alwaysAllow)) == .needsApproval(.automaticApprovalForbidden))
    }

    @Test func egressRequiresDeclaredDestinationAndConfirmation() {
        #expect(ToolPolicyEvaluator.evaluate(input(action: metadata(egress: .providerRequiringApproval), mode: .alwaysAllow)) == .needsApproval(.explicitApprovalRequired))
        let noDestination = ToolPolicyScopeTests().call(destination: .notRequired)
        #expect(ToolPolicyEvaluator.evaluate(input(mode: .alwaysAllow, call: noDestination)) == .dependencyChanged(.invalidDestinationScope))
        #expect(ToolPolicyEvaluator.evaluate(input(action: metadata(egress: .notRequired), mode: .alwaysAllow)) == .dependencyChanged(.invalidDestinationScope))
    }

    @Test(arguments: [ToolResourceScope.notRequired, .missing, .target("target"), .file(assetID: "asset", versionID: "", contentIdentity: "digest")])
    func requiredResourceCannotBeOmittedOrSubstituted(resource: ToolResourceScope) {
        #expect(ToolPolicyEvaluator.evaluate(input(mode: .alwaysAllow, call: ToolPolicyScopeTests().call(resource: resource))) == .dependencyChanged(.invalidResourceScope))
    }

    @Test func scopeLessActionNeedsExplicitNoRequirements() {
        let action = metadata(resource: .notRequired, egress: .notRequired)
        let call = ToolPolicyScopeTests().call(resource: .notRequired, destination: .notRequired)
        #expect(ToolPolicyEvaluator.evaluate(input(action: action, mode: .alwaysAllow, call: call)) == .allow(.globalPolicy))
    }

    @Test func separateSourceAndSinkGrantsCannotCombine() {
        let scope = ToolPolicyScopeTests()
        let source = scope.grant(destination: .notRequired)
        let sink = scope.grant(resource: .notRequired)
        #expect(ToolPolicyEvaluator.evaluate(input(grants: [source, sink])) == .needsApproval(.noApplicableGrant))
    }

    @Test func descriptorChangeCannotReuseOldApproval() {
        #expect(ToolPolicyEvaluator.evaluate(input(action: metadata(revision: "r2"), grants: [ToolPolicyScopeTests().grant()])) == .dependencyChanged(.descriptorChanged))
    }

    @Test func staleOrWrongPolicyCannotProvideAutomaticPermission() {
        for snapshot in [policy(tool: "other", mode: .alwaysAllow), policy(action: "delete", mode: .alwaysAllow), policy(revision: "r2", mode: .alwaysAllow)] {
            #expect(ToolPolicyEvaluator.evaluate(input(currentPolicy: snapshot)) == .dependencyChanged(.policyChanged))
        }
    }

    @Test func currentResolutionMustMatchFrozenIntent() {
        #expect(ToolPolicyEvaluator.evaluate(input(mode: .alwaysAllow, resolvedResource: .file(assetID: "other", versionID: "version", contentIdentity: "digest"))) == .dependencyChanged(.resourceChanged))
        #expect(ToolPolicyEvaluator.evaluate(input(mode: .alwaysAllow, resolvedDestination: .provider(instanceID: "other", endpointIdentity: "endpoint"))) == .dependencyChanged(.destinationChanged))
        #expect(ToolPolicyEvaluator.evaluate(input(mode: .alwaysAllow, resolvedBinding: "changed")) == .dependencyChanged(.intentChanged))
    }

    @Test func grantOrderDoesNotChangeEffectiveDecision() {
        let scope = ToolPolicyScopeTests()
        let once = scope.grant(kind: .once(toolCallID: "call", agentRunID: "run", intentBinding: "intent"))
        let conversation = scope.grant()
        #expect(ToolPolicyEvaluator.evaluate(input(grants: [once, conversation])) == .allow(.onceGrant))
        #expect(ToolPolicyEvaluator.evaluate(input(grants: [conversation, once])) == .allow(.onceGrant))
    }

    @Test func sameInputProducesSameDecision() {
        let value = input(mode: .alwaysAllow)
        for _ in 0..<5 { #expect(ToolPolicyEvaluator.evaluate(value) == .allow(.globalPolicy)) }
    }

    func permitted(_ kind: ToolGrantKind) -> ToolPolicyDecision {
        if case .once = kind { return .allow(.onceGrant) }
        return .allow(.conversationGrant)
    }

    func metadata(risk: ToolActionRisk = .low, allowsAutomatic: Bool = true, allowsConversation: Bool = true,
                  resource: ToolPolicyResourceRequirement = .file, egress: ToolPolicyEgressRequirement = .provider,
                  revision: String = "r1") -> ToolPolicyActionMetadata {
        ToolPolicyActionMetadata(toolID: "files", actionID: "read", descriptorRevision: revision, risk: risk,
                                 allowsAutomaticApproval: allowsAutomatic, allowsConversationGrant: allowsConversation,
                                 resourceRequirement: resource, egressRequirement: egress)
    }

    func policy(tool: String = "files", action: String = "read", revision: String = "r1", mode: ToolPersistentPolicy = .askEveryTime, epoch: UInt64 = 0) -> ToolPolicySnapshot {
        ToolPolicySnapshot(toolID: tool, actionID: action, descriptorRevision: revision, mode: mode, revocationEpoch: epoch)
    }

    func input(action: ToolPolicyActionMetadata? = ToolPolicyEvaluatorTests.ordinaryAction,
               cap: ToolPolicySafetyCap = .unrestricted, mode: ToolPersistentPolicy = .askEveryTime,
               createdPolicy: ToolPolicySnapshot? = nil, admission: ToolPolicyAdmissionDisposition = .allowed,
               admissionBinding: String? = nil, currentPolicy: ToolPolicySnapshot? = nil, call: ToolPolicyCallContext? = nil,
               resolvedResource: ToolResourceScope? = nil, resolvedDestination: ToolDestinationScope? = nil,
               resolvedBinding: String? = nil, grants: [ToolScopedGrant] = []) -> ToolPolicyEvaluationInput {
        let context = call ?? ToolPolicyScopeTests().call()
        let current = currentPolicy ?? policy(mode: mode)
        return ToolPolicyEvaluationInput(action: action, safetyCap: cap, policyAtCreation: createdPolicy ?? current,
                                         admission: ToolPolicyAdmission(disposition: admission, intentBinding: admissionBinding ?? context.intentBinding),
                                         currentPolicy: current, call: context, resolvedResource: resolvedResource ?? context.resource,
                                         resolvedDestination: resolvedDestination ?? context.destination,
                                         resolvedIntentBinding: resolvedBinding ?? context.intentBinding, grants: grants)
    }
}

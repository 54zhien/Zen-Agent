enum ToolPolicyEvaluator {
    static func evaluate(_ input: ToolPolicyEvaluationInput) -> ToolPolicyDecision {
        let call = input.call
        guard call.hasValidIdentity else { return .dependencyChanged(.invalidIdentity) }
        guard call.authorizationIsAvailable else { return .deny(.authorizationUnavailable) }
        guard call.subjectIsAvailable else { return .deny(.subjectUnavailable) }
        if input.safetyCap == .deny { return .deny(.hardDeny) }
        if input.safetyCap == .unknown { return .deny(.unknownSafetyCap) }
        guard input.currentPolicy.bindsLogicalAction(call) else { return .dependencyChanged(.policyChanged) }
        if input.currentPolicy.mode == .deny { return .deny(.globalDeny) }
        guard input.currentPolicy.binds(call) else { return .dependencyChanged(.policyChanged) }
        guard let action = input.action, action.isKnown else { return .deny(.unknownMetadata) }
        guard ToolPolicyIdentity.equals(action.toolID, call.toolID), ToolPolicyIdentity.equals(action.actionID, call.actionID) else {
            return .dependencyChanged(.actionChanged)
        }
        guard ToolPolicyIdentity.equals(action.descriptorRevision, call.descriptorRevision) else {
            return .dependencyChanged(.descriptorChanged)
        }
        guard action.resourceRequirement.accepts(call.resource) else {
            return .dependencyChanged(.invalidResourceScope)
        }
        guard action.egressRequirement.accepts(call.destination) else {
            return .dependencyChanged(.invalidDestinationScope)
        }
        guard input.resolvedResource == call.resource else { return .dependencyChanged(.resourceChanged) }
        guard input.resolvedDestination == call.destination else { return .dependencyChanged(.destinationChanged) }
        guard ToolPolicyIdentity.equals(input.resolvedIntentBinding, call.intentBinding) else { return .dependencyChanged(.intentChanged) }
        if input.policyAtCreation.bindsLogicalAction(call),
           input.policyAtCreation.revocationEpoch > input.currentPolicy.revocationEpoch {
            return .dependencyChanged(.stalePolicySnapshot)
        }

        // Widening is not retroactive. A previous wait, tightening or reprepare
        // needs approval of this call, not another call's new conversation grant.
        let requiresCurrentApproval = input.admission.disposition != .allowed
            || !input.policyAtCreation.binds(call)
            || !ToolPolicyIdentity.equals(input.admission.intentBinding, call.intentBinding)
            || input.policyAtCreation.revocationEpoch != input.currentPolicy.revocationEpoch

        // One grant must cover the entire subject × action × source/destination.
        // Separate source and sink grants never combine into an egress permission.
        let matching = input.grants.filter {
            $0.revocationEpoch == input.currentPolicy.revocationEpoch
                && ToolGrantScopeMatcher.matches(grant: $0, call: call)
        }
        if matching.contains(where: { if case .once = $0.kind { return true }; return false }) {
            return .allow(.onceGrant)
        }
        let hasConversationGrant = matching.contains { $0.kind == .conversation }
        if hasConversationGrant {
            guard action.allowsConversationGrant else { return .needsApproval(.conversationGrantForbidden) }
            if !requiresCurrentApproval || matching.contains(where: {
                $0.kind == .conversation && $0.issuedFor?.binds(call) == true
            }) {
                return .allow(.conversationGrant)
            }
        }

        if requiresCurrentApproval { return .needsApproval(.priorApprovalRequired) }

        if input.safetyCap == .requiresExplicitApproval || action.requiresExplicitApproval {
            return .needsApproval(.explicitApprovalRequired)
        }
        if input.currentPolicy.mode == .alwaysAllow {
            guard action.allowsAutomaticApproval else { return .needsApproval(.automaticApprovalForbidden) }
            guard input.policyAtCreation.mode == .alwaysAllow else { return .needsApproval(.priorApprovalRequired) }
            return .allow(.globalPolicy)
        }
        return .needsApproval(.noApplicableGrant)
    }
}

enum ToolPolicyEvaluator {
    static func evaluate(_ input: ToolPolicyEvaluationInput) -> ToolPolicyDecision {
        let call = input.call
        guard call.hasValidIdentity else { return .dependencyChanged(.invalidIdentity) }
        if input.safetyCap == .deny { return .deny(.hardDeny) }
        if input.safetyCap == .unknown { return .deny(.unknownSafetyCap) }
        guard input.currentPolicy.bindsLogicalAction(call) else { return .dependencyChanged(.policyChanged) }
        if input.currentPolicy.mode == .deny { return .deny(.globalDeny) }
        guard input.currentPolicy.binds(call) else { return .dependencyChanged(.policyChanged) }
        guard let action = input.action, action.isKnown else { return .deny(.unknownMetadata) }
        guard action.toolID == call.toolID, action.actionID == call.actionID else {
            return .dependencyChanged(.actionChanged)
        }
        guard action.descriptorRevision == call.descriptorRevision else {
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
        guard input.resolvedIntentBinding == call.intentBinding else { return .dependencyChanged(.intentChanged) }

        // One grant must cover the entire subject × action × source/destination.
        // Separate source and sink grants never combine into an egress permission.
        let matching = input.grants.filter { ToolGrantScopeMatcher.matches(grant: $0, call: call) }
        if matching.contains(where: { if case .once = $0.kind { return true }; return false }) {
            return .allow(.onceGrant)
        }
        let hasConversationGrant = matching.contains { $0.kind == .conversation }
        if hasConversationGrant, action.allowsConversationGrant { return .allow(.conversationGrant) }
        if hasConversationGrant { return .needsApproval(.conversationGrantForbidden) }

        if input.safetyCap == .requiresExplicitApproval || action.requiresExplicitApproval {
            return .needsApproval(.explicitApprovalRequired)
        }
        if input.currentPolicy.mode == .alwaysAllow {
            guard action.allowsAutomaticApproval else { return .needsApproval(.automaticApprovalForbidden) }
            return .allow(.globalPolicy)
        }
        return .needsApproval(.noApplicableGrant)
    }
}

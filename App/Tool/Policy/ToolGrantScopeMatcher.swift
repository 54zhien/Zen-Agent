enum ToolGrantScopeMatcher {
    static func matches(grant: ToolScopedGrant, call: ToolPolicyCallContext) -> Bool {
        guard call.hasValidIdentity,
              call.authorizationIsAvailable, call.subjectIsAvailable,
              grant.validity == .active,
              call.resource.isValid, grant.resource.isValid,
              call.destination.isValid, grant.destination.isValid,
              grant.subject == call.subject,
              ToolPolicyIdentity.equals(grant.toolID, call.toolID),
              ToolPolicyIdentity.equals(grant.actionID, call.actionID),
              ToolPolicyIdentity.equals(grant.descriptorRevision, call.descriptorRevision),
              grant.resource == call.resource,
              grant.destination == call.destination else { return false }

        switch grant.kind {
        case .once(let callID, let runID, let binding):
            return ToolPolicyIdentity.equals(callID, call.toolCallID)
                && ToolPolicyIdentity.equals(runID, call.agentRunID)
                && ToolPolicyIdentity.equals(binding, call.intentBinding)
        case .conversation:
            // Exact declared scope can cover later calls, never other subjects.
            return true
        }
    }
}

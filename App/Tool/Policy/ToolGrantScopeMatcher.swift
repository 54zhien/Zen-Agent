enum ToolGrantScopeMatcher {
    static func matches(grant: ToolScopedGrant, call: ToolPolicyCallContext) -> Bool {
        guard call.hasValidIdentity,
              grant.validity == .active,
              call.resource.isValid, grant.resource.isValid,
              call.destination.isValid, grant.destination.isValid,
              grant.subject == call.subject,
              grant.toolID == call.toolID,
              grant.actionID == call.actionID,
              grant.descriptorRevision == call.descriptorRevision,
              grant.resource == call.resource,
              grant.destination == call.destination else { return false }

        switch grant.kind {
        case .once(let callID, let runID, let binding):
            return callID == call.toolCallID
                && runID == call.agentRunID
                && binding == call.intentBinding
        case .conversation:
            // Exact declared scope can cover later calls, never other subjects.
            return true
        }
    }
}

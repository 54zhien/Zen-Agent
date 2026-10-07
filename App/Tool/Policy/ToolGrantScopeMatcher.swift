enum ToolGrantScopeMatcher {
    static func matches(grant: ToolScopedGrant, call: ToolPolicyCallContext) -> Bool {
        // Conservative compileable RED seam; never connected to dispatch.
        false
    }
}

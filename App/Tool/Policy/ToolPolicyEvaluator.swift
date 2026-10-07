enum ToolPolicyEvaluator {
    static func evaluate(_ input: ToolPolicyEvaluationInput) -> ToolPolicyDecision {
        // Conservative compileable RED seam; no production caller exists.
        .deny(.hardDeny)
    }
}

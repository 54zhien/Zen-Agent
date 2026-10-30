/// Confirmation queries immutable completion proof; it never repeats an effect.
protocol ToolOutcomeConfirming: ToolExecutable {
    func confirmedResult(_ intent: ToolExecutionIntent, idempotencyKey: String) throws -> ToolExecutionResult?
}

/// Persisted operation receipts can have different authoritative owners. Most tools
/// use the file-operation receipt table; delegation confirms the Child Run and its
/// original Parent ToolCall in one transaction instead.
protocol DelegatedToolOutcomeConfirming: ToolOutcomeConfirming {
    func persistConfirmedResult(
        _ result: ToolExecutionResult,
        observedResult: ToolExecutionResult,
        intent: ToolExecutionIntent,
        idempotencyKey: String
    ) throws -> Bool
}

protocol DelegatedToolRecoveryResuming: ToolExecutable {
    func resumeUnstartedChild(
        _ intent: ToolExecutionIntent,
        idempotencyKey: String
    ) async throws

    func failUnknownChildren(parentRunID: String) throws
}

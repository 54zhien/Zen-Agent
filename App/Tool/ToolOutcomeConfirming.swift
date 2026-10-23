/// Confirmation queries immutable completion proof; it never repeats an effect.
protocol ToolOutcomeConfirming: ToolExecutable {
    func confirmedResult(_ intent: ToolExecutionIntent, idempotencyKey: String) throws -> ToolExecutionResult?
}

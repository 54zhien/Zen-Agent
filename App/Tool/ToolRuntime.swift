import Foundation

enum ToolRuntimeError: Error, Equatable, Sendable {
    case unknownTool(String)
    case toolCallNotFound(String)
    case invalidContinuationIdentity
    case invalidToolCallState(id: String, expected: ToolCallState, actual: ToolCallState)
    case missingExecutionIntent(String)
    case invalidStoredExecutionIntent(String)
    case cancellationSettlementFailed(
        providerCallID: String,
        crossedDispatchBoundary: Bool,
        leftDurableCallNonterminal: Bool,
        reason: String
    )
}

/// The Stage 2 boundary between a provider tool call and an external executor.
///
/// The runtime deliberately keeps the dispatch marker and executor call as two
/// separate operations. `markToolCallDispatched` commits before `execute` is entered;
/// a crash after that commit is therefore recovered as uncertain rather than retried.
final class ToolRuntime: @unchecked Sendable {
    private let store: PersistenceStore
    private let registry: ToolRegistry

    init(store: PersistenceStore, registry: ToolRegistry) {
        self.store = store
        self.registry = registry
    }

    /// Completes one provider tool call through validation, frozen intent persistence,
    /// approval (when required), dispatch and durable settlement.
    ///
    /// A call waiting for approval returns `nil`. Approval keeps that same persisted call;
    /// a caller may continue it after approval with `executeApproved`.
    func complete(
        agentRunID: String,
        providerCallID: String,
        toolID: String,
        argumentsJSON: String,
        batchID: String,
        batchSequence: Int,
        at now: Date = Date()
    ) async throws -> ToolExecutionResult? {
        guard
            !providerCallID.isEmpty,
            !batchID.isEmpty
        else {
            throw ToolRuntimeError.invalidContinuationIdentity
        }

        guard
            let descriptor = registry.descriptor(id: toolID),
            let executor = registry.executor(id: toolID)
        else {
            throw ToolRuntimeError.unknownTool(toolID)
        }

        let callID = UUID().uuidString
        let intent = try executor.prepare(callID: callID, argumentsJSON: argumentsJSON)
        guard
            intent.formatVersion == ToolExecutionIntent.currentFormatVersion,
            intent.toolID == descriptor.id,
            intent.descriptorRevision == descriptor.revision
        else {
            throw ToolExecutionError.invalidIntent
        }

        let intentJSON = try encode(intent)
        let state: ToolCallState = descriptor.approvalRequirement == .required
            ? .waitingForApproval
            : .prepared
        let call = ToolCallRecord(
            id: callID,
            agentRunID: agentRunID,
            action: descriptor.id,
            state: state,
            executionIntent: intentJSON,
            attempt: 1,
            providerCallID: providerCallID,
            batchID: batchID,
            batchSequence: batchSequence,
            createdAt: now,
            updatedAt: now
        )
        try store.createToolCall(call)

        guard state == .prepared else {
            return nil
        }
        return try await executePrepared(toolCallID: callID, at: now)
    }

    /// Converts an unavailable provider call into a durable model-visible rejection.
    /// The direct `complete` API remains strict and reports `unknownTool`; the Agent
    /// Runtime uses this path so one rejected call does not discard the rest of a
    /// provider batch.
    func rejectUnknown(
        agentRunID: String,
        providerCallID: String,
        toolID: String,
        batchID: String,
        batchSequence: Int,
        at now: Date = Date()
    ) throws -> ToolExecutionResult {
        let callID = UUID().uuidString
        let result = ToolExecutionResult(
            content: "Tool execution was rejected: the tool is not available."
        )
        try store.createRejectedToolCall(
            ToolCallRecord(
                id: callID,
                agentRunID: agentRunID,
                action: toolID,
                state: .rejected,
                executionIntent: nil,
                attempt: 1,
                providerCallID: providerCallID,
                batchID: batchID,
                batchSequence: batchSequence,
                createdAt: now,
                updatedAt: now
            ),
            result: ToolResultRecord(
                toolCallID: callID,
                payload: result.content,
                createdAt: now
            )
        )
        return result
    }

    /// Settles one call when a parent stop interrupts a serial batch. Calls that have
    /// not crossed dispatch are safe `notExecuted`; dispatched calls remain
    /// `indeterminate` because cancellation cannot prove the external side effect.
    func settleForCancellation(
        agentRunID: String,
        providerCallID: String,
        toolID: String,
        batchID: String,
        batchSequence: Int,
        at now: Date = Date()
    ) throws {
        let call: ToolCallRecord?
        do {
            call = try store.toolCalls(inRun: agentRunID).first(where: {
                $0.providerCallID == providerCallID &&
                    $0.batchID == batchID &&
                    $0.batchSequence == batchSequence
            })
        } catch {
            throw ToolRuntimeError.cancellationSettlementFailed(
                providerCallID: providerCallID,
                crossedDispatchBoundary: true,
                leftDurableCallNonterminal: true,
                reason: String(describing: error)
            )
        }

        do {
            if let call {
                try store.settleToolCallForCancellation(id: call.id, at: now)
                return
            }

            try store.createToolCall(
                ToolCallRecord(
                    id: UUID().uuidString,
                    agentRunID: agentRunID,
                    action: toolID,
                    state: .notExecuted,
                    executionIntent: nil,
                    attempt: 1,
                    providerCallID: providerCallID,
                    batchID: batchID,
                    batchSequence: batchSequence,
                    createdAt: now,
                    updatedAt: now
                )
            )
        } catch {
            let crossedDispatchBoundary = call?.state == .dispatched
            let leftDurableCallNonterminal: Bool
            if let state = call?.state {
                switch state {
                case .validated,
                     .waitingForApproval,
                     .waitingForSystemPermissionConsent,
                     .approved,
                     .prepared,
                     .dispatched:
                    leftDurableCallNonterminal = true
                case .succeeded,
                     .failed,
                     .rejected,
                     .cancelled,
                     .notExecuted,
                     .indeterminate:
                    leftDurableCallNonterminal = false
                }
            } else {
                leftDurableCallNonterminal = false
            }
            throw ToolRuntimeError.cancellationSettlementFailed(
                providerCallID: providerCallID,
                crossedDispatchBoundary: crossedDispatchBoundary,
                leftDurableCallNonterminal: leftDurableCallNonterminal,
                reason: String(describing: error)
            )
        }
    }

    /// Records approval on the existing waiting call. Execution is intentionally a
    /// separate operation so approval presentation cannot accidentally cross the
    /// durable-dispatch boundary.
    func approve(toolCallID: String) throws {
        try store.approveToolCall(id: toolCallID)
    }

    /// Rejects the waiting call and stores the model-visible rejection as its result.
    func reject(toolCallID: String, at now: Date = Date()) throws -> ToolExecutionResult {
        let result = ToolExecutionResult(content: "Tool execution was rejected by the user.")
        try store.rejectWaitingForApprovalToolCall(
            id: toolCallID,
            result: ToolResultRecord(
                toolCallID: toolCallID,
                payload: result.content,
                createdAt: now
            ),
            at: now
        )
        return result
    }

    /// Resumes the same call after `approve` or after a restart restored its approved
    /// state. It never creates a second ToolCall identity.
    func executeApproved(
        toolCallID: String,
        at now: Date = Date()
    ) async throws -> ToolExecutionResult {
        let call = try requiredToolCall(id: toolCallID)
        guard call.state == .approved else {
            throw ToolRuntimeError.invalidToolCallState(
                id: toolCallID,
                expected: .approved,
                actual: call.state
            )
        }
        try store.markToolCallPrepared(id: toolCallID, at: now)
        return try await executePrepared(toolCallID: toolCallID, at: now)
    }

    private func executePrepared(
        toolCallID: String,
        at now: Date
    ) async throws -> ToolExecutionResult {
        let call = try requiredToolCall(id: toolCallID)
        guard call.state == .prepared else {
            throw ToolRuntimeError.invalidToolCallState(
                id: toolCallID,
                expected: .prepared,
                actual: call.state
            )
        }
        guard let executionIntent = call.executionIntent else {
            throw ToolRuntimeError.missingExecutionIntent(toolCallID)
        }
        let intent = try decodeIntent(executionIntent, callID: toolCallID)
        guard let executor = registry.executor(id: intent.toolID) else {
            throw ToolRuntimeError.unknownTool(intent.toolID)
        }
        guard
            intent.formatVersion == ToolExecutionIntent.currentFormatVersion,
            intent.toolID == executor.descriptor.id,
            intent.descriptorRevision == executor.descriptor.revision,
            call.action == intent.toolID
        else {
            throw ToolExecutionError.invalidIntent
        }

        // This write must complete before the executor is entered.
        try store.markToolCallDispatched(id: toolCallID, at: now)

        let executionResult: ToolExecutionResult
        do {
            executionResult = try await executor.execute(
                intent,
                idempotencyKey: call.id
            )
        } catch {
            if error is CancellationError || Task.isCancelled {
                // This marker is the durable proof that recovery must not retry the
                // external operation. A failed write is therefore a real runtime
                // error, never an ignorable side effect of cancellation.
                try store.markToolCallIndeterminate(id: call.id, at: now)
                throw error
            }
            let failureResult = ToolExecutionResult(
                content: "Tool execution failed: \(String(describing: error))"
            )
            try store.finishDispatchedToolCall(
                id: call.id,
                expectedAttempt: call.attempt,
                state: .failed,
                result: ToolResultRecord(
                    toolCallID: call.id,
                    payload: failureResult.content,
                    createdAt: now
                ),
                at: now
            )
            throw error
        }

        try store.finishDispatchedToolCall(
            id: call.id,
            expectedAttempt: call.attempt,
            state: .succeeded,
            result: ToolResultRecord(
                toolCallID: call.id,
                payload: executionResult.content,
                createdAt: now
            ),
            at: now
        )
        return executionResult
    }

    private func requiredToolCall(id: String) throws -> ToolCallRecord {
        guard let call = try store.toolCall(id: id) else {
            throw ToolRuntimeError.toolCallNotFound(id)
        }
        return call
    }

    private func encode(_ intent: ToolExecutionIntent) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(intent)
        guard let string = String(data: data, encoding: .utf8) else {
            throw ToolRuntimeError.invalidStoredExecutionIntent("encoding")
        }
        return string
    }

    private func decodeIntent(
        _ json: String,
        callID: String
    ) throws -> ToolExecutionIntent {
        guard let data = json.data(using: .utf8) else {
            throw ToolRuntimeError.invalidStoredExecutionIntent(callID)
        }
        do {
            return try JSONDecoder().decode(ToolExecutionIntent.self, from: data)
        } catch {
            throw ToolRuntimeError.invalidStoredExecutionIntent(callID)
        }
    }
}

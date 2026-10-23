import Foundation

enum ToolRuntimeError: Error, Equatable, Sendable {
    case unknownTool(String)
    case toolCallNotFound(String)
    case invalidContinuationIdentity
    case approvalRequired(String)
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
/// The original frozen payload, policy admission and current grants are checked
/// at the transactional dispatch boundary. System-consent wiring remains S6-04b.
final class ToolRuntime: @unchecked Sendable {
    private let store: PersistenceStore
    private let registry: ToolRegistry
    private let safetyCap: ToolPolicySafetyCap
    private let systemConsent: ToolSystemConsentRuntime

    init(store: PersistenceStore, registry: ToolRegistry, safetyCap: ToolPolicySafetyCap = .unrestricted) {
        self.store = store
        self.registry = registry
        self.safetyCap = safetyCap
        self.systemConsent = ToolSystemConsentRuntime(store: store, registry: registry, safetyCap: safetyCap)
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
            let executor = registry.executor(id: toolID),
            ToolPolicyIdentity.equals(toolID, descriptor.id)
        else {
            throw ToolRuntimeError.unknownTool(toolID)
        }

        let callID = UUID().uuidString
        let intent: ToolExecutionIntent
        do {
            intent = try executor.prepare(callID: callID, argumentsJSON: argumentsJSON)
            try ToolIntentCodec.validate(intent, descriptor: descriptor)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let failure = (error as? ToolIntentFailure)
                ?? ((error as? ToolExecutionError) == .invalidArguments ? .invalidArguments : .preparationFailed)
            let result = ToolExecutionResult(content: failure.resultContent)
            // A rejected transcript retains the original arguments for cold
            // continuation, but has no executable action/scope authority.
            let representation = ToolExecutionIntent(
                formatVersion: ToolExecutionIntent.currentFormatVersion, toolID: descriptor.id,
                descriptorRevision: descriptor.revision, normalizedArgumentsJSON: argumentsJSON,
                targetIdentity: nil, destinationIdentity: nil
            )
            try store.createRejectedToolCall(ToolCallRecord(
                id: callID, agentRunID: agentRunID, action: descriptor.id, state: .rejected,
                executionIntent: try encode(representation), attempt: 1, providerCallID: providerCallID,
                batchID: batchID, batchSequence: batchSequence, createdAt: now, updatedAt: now
            ), result: ToolResultRecord(toolCallID: callID, payload: result.content, createdAt: now))
            return result
        }

        let intentJSON = try encode(intent)
        let state = ToolCallState.validated
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
        try Task.checkCancellation()
        let admitted = try store.createToolCallWithPolicy(call, descriptor: descriptor, safetyCap: safetyCap, at: now)
        switch admitted.state {
        case .prepared:
            do { return try await executePrepared(toolCallID: callID, at: now) }
            catch ToolSystemPermissionError.consentRequired { return nil }
        case .rejected: return try storedResult(for: admitted.id)
        case .notExecuted: throw CancellationError()
        default: return nil
        }
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
    func approve(toolCallID: String, displayedIntentBinding: String? = nil, scope: ToolApprovalScope = .once) throws {
        if try validatePendingIntent(toolCallID: toolCallID, requireAdmission: false) != nil { return }
        let call = try requiredToolCall(id: toolCallID)
        guard let json = call.executionIntent,
              let intent = try? ToolIntentCodec.decodeForDisplay(json),
              let descriptor = registry.executor(id: intent.toolID)?.descriptor else {
            throw ToolRuntimeError.missingExecutionIntent(toolCallID)
        }
        let approved = try store.approveToolCallWithPolicy(id: call.id, expectedAttempt: call.attempt,
            descriptor: descriptor, safetyCap: safetyCap, checkedIntentBinding: ToolIntentBinding.make(json),
            displayedIntentBinding: displayedIntentBinding, scope: scope, at: Date())
        if approved.state == .waitingForApproval { throw ToolRuntimeError.approvalRequired(call.id) }
        if approved.state == .notExecuted { throw CancellationError() }
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
        if let rejection = try validatePendingIntent(toolCallID: call.id, at: now) { return rejection }
        try requireExecutablePendingCall(call.id)
        try store.markToolCallPrepared(id: toolCallID, at: now)
        return try await executePrepared(toolCallID: toolCallID, at: now)
    }

    /// Reuses the original prepared call on cold-start recovery. Dispatch is still
    /// marked durably before the executor is entered, as in the ordinary path.
    func executePrepared(
        toolCallID: String,
        at now: Date = Date()
    ) async throws -> ToolExecutionResult {
        let call = try requiredToolCall(id: toolCallID)
        guard call.state == .prepared else {
            throw ToolRuntimeError.invalidToolCallState(
                id: toolCallID,
                expected: .prepared,
                actual: call.state
            )
        }
        if let rejection = try validatePendingIntent(toolCallID: call.id, at: now) { return rejection }
        try requireExecutablePendingCall(call.id)
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

        try Task.checkCancellation()
        if executor is any ToolSystemPermissionProviding {
            let systemChecked = try await systemConsent.preflight(call: call, intent: intent, executor: executor)
            if systemChecked.state == .rejected { return try storedResult(for: call.id) }
            if systemChecked.state == .waitingForSystemPermissionConsent {
                throw ToolSystemPermissionError.consentRequired(call.id)
            }
            if systemChecked.state == .waitingForApproval { throw ToolRuntimeError.approvalRequired(call.id) }
            if systemChecked.state == .notExecuted { throw CancellationError() }
            // OS reads can suspend. Revalidate the frozen dependencies after
            // returning, then leave no await before the existing dispatch write.
            if let rejection = try validatePendingIntent(toolCallID: call.id, at: now) { return rejection }
            try requireExecutablePendingCall(call.id)
        }
        // Current authority and the original attempt commit together. The exact
        // JSON this checkpoint authorizes is the payload passed to execute below.
        let dispatched = try store.dispatchToolCallWithPolicy(id: call.id, expectedAttempt: call.attempt,
            descriptor: executor.descriptor, safetyCap: safetyCap,
            checkedIntentBinding: ToolIntentBinding.make(executionIntent), at: now)
        switch dispatched.state {
        case .dispatched: break
        case .rejected: return try storedResult(for: call.id)
        case .notExecuted: throw CancellationError()
        case .waitingForApproval: throw ToolRuntimeError.approvalRequired(call.id)
        default: throw ToolRuntimeError.invalidToolCallState(id: call.id, expected: .dispatched, actual: dispatched.state)
        }

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

    /// Cold recovery and dispatch share this check. Terminal calls are historical
    /// results, while dispatched calls remain owned by uncertain-outcome recovery.
    func validatePendingIntent(toolCallID: String, at now: Date = Date(),
                               requireAdmission: Bool = true) throws -> ToolExecutionResult? {
        let call = try requiredToolCall(id: toolCallID)
        guard [ToolCallState.validated, .waitingForApproval, .waitingForSystemPermissionConsent, .approved, .prepared].contains(call.state) else { return nil }
        let descriptor: ToolDescriptor
        do {
            guard let json = call.executionIntent else { throw ToolIntentFailure.malformedIntent }
            let intent = try ToolIntentCodec.decodeForDisplay(json)
            guard let executor = registry.executor(id: intent.toolID),
                  ToolPolicyIdentity.equals(call.action, intent.toolID)
            else { throw ToolIntentFailure.descriptorChanged }
            descriptor = executor.descriptor
            try ToolIntentCodec.validate(intent, descriptor: descriptor)
            try executor.validateDependencies(intent)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let failure = (error as? ToolIntentFailure) ?? .dependenciesChanged
            let reason: ToolCallFailureReason = switch failure {
            case .descriptorChanged, .actionChanged, .legacyIntentRequiresReapproval, .unsupportedVersion:
                .reapprovalNeeded
            default: .dependencyChanged
            }
            let result = ToolExecutionResult(content: failure.resultContent)
            try store.rejectUndispatchedToolCall(id: call.id, expectedAttempt: call.attempt,
                result: ToolResultRecord(toolCallID: call.id, payload: result.content, createdAt: now),
                at: now, failureReason: reason)
            return result
        }
        if requireAdmission, let json = call.executionIntent {
            let reconciled = try store.reconcileToolCallPolicy(id: call.id, expectedAttempt: call.attempt,
                descriptor: descriptor, safetyCap: safetyCap, checkedIntentBinding: ToolIntentBinding.make(json), at: now)
            if reconciled.state == .rejected { return try storedResult(for: call.id) }
        }
        return nil
    }

    func resolveSystemPermission(toolCallID: String, displayedIntentBinding: String,
                                 consent: Bool) async throws {
        if try validatePendingIntent(toolCallID: toolCallID) != nil { return }
        try await systemConsent.resolve(id: toolCallID, binding: displayedIntentBinding, consent: consent,
            revalidate: { try self.validatePendingIntent(toolCallID: toolCallID) == nil })
    }

    func recoverSystemPermission(toolCallID: String) async throws {
        if try validatePendingIntent(toolCallID: toolCallID) != nil { return }
        guard try requiredToolCall(id: toolCallID).state == .waitingForSystemPermissionConsent else { return }
        try await systemConsent.recover(id: toolCallID,
            revalidate: { try self.validatePendingIntent(toolCallID: toolCallID) == nil })
    }

    private func requireExecutablePendingCall(_ id: String) throws {
        let call = try requiredToolCall(id: id)
        if call.state == .waitingForApproval { throw ToolRuntimeError.approvalRequired(id) }
        if call.state == .notExecuted { throw CancellationError() }
    }

    private func storedResult(for id: String) throws -> ToolExecutionResult {
        guard let result = try store.toolResult(toolCallID: id) else {
            throw ToolRuntimeError.invalidStoredExecutionIntent(id)
        }
        return ToolExecutionResult(content: result.payload)
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
        do {
            return try ToolIntentCodec.decodeForDisplay(json)
        } catch {
            throw ToolRuntimeError.invalidStoredExecutionIntent(callID)
        }
    }
}

import Foundation

typealias AgentEventProjection = @Sendable (AgentEvent) async throws -> Void

/// Errors that prevent an AgentRuntime stream from being started at all. Provider
/// failures after a run exists are business outcomes and are written to the Run row
/// instead of escaping as these errors.
enum AgentRuntimeError: Error, Equatable, Sendable {
    case alreadyRunning(String)
    case runNotFound(String)
    case runIsNotActive(String)
}

/// The sole owner of Run state transitions for an executing Parent Run.
///
/// This type never writes a Message or MessagePart. It emits business events for the
/// ConversationRuntime, which is the only layer allowed to materialise assistant
/// content. The storage calls here are limited to Run/Step lifecycle and the stale
/// attempt guard.
actor AgentRuntime {

    private final class ContinuationBox: @unchecked Sendable {
        var value: AsyncThrowingStream<AgentEvent, Error>.Continuation?
    }

    private enum ControlError: Error {
        case stopRequested
        case projectionFailed
    }

    private enum FailureDisposition {
        case failed(EndReason)
        case suspended(SuspendReason)
    }

    private struct OutputState {
        var accumulator = StreamingAccumulator()
        let messageID: String
        var partID: String
        var text = ""
        var started = false

        mutating func resetPart(runID: String) {
            accumulator = StreamingAccumulator()
            partID = "part-\(runID)-\(UUID().uuidString)"
            text = ""
            started = false
        }
    }

    private struct ActiveToolBatch {
        let calls: [ProviderToolCall]
        let batchID: String
    }

    private struct ToolBatchCall {
        let providerCall: ProviderToolCall
        let record: ToolCallRecord
        let result: ToolResultRecord?
    }

    private enum ToolBatchDisposition {
        case continueWith(ProviderChatRequest)
        case waitingForApproval
    }

    private struct ActiveExecution {
        let task: Task<Void, Never>
        let continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
        let project: AgentEventProjection
    }

    private let store: PersistenceStore
    private let provider: any ModelProvider
    private let credentials: any CredentialStoring
    private let toolRuntime: ToolRuntime

    private var active: [String: ActiveExecution] = [:]
    private var stopRequested: Set<String> = []
    private var toolDecisionWaiters: [String: CheckedContinuation<Void, Never>] = [:]

    init(
        store: PersistenceStore,
        provider: any ModelProvider,
        credentials: any CredentialStoring,
        toolRuntime: ToolRuntime? = nil
    ) {
        self.store = store
        self.provider = provider
        self.credentials = credentials
        self.toolRuntime = toolRuntime ?? ToolRuntime(
            store: store,
            registry: ToolRegistry.empty
        )
    }

    /// Starts one provider attempt and returns its ordered business-event stream.
    ///
    /// The step identity is created from durable rows inside `execute`, not from an
    /// in-memory counter, so a later recovery cannot reset the loop budget.
    /// `project` is awaited before each event is released to the stream, making the
    /// ConversationRuntime's durable apply the acknowledgement boundary for content.
    func advance(
        runID: String,
        request: ProviderChatRequest,
        snapshot: RunExecutionSnapshot,
        project: @escaping AgentEventProjection = { _ in }
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        let box = ContinuationBox()
        let stream = AsyncThrowingStream<AgentEvent, Error> { created in
            box.value = created
        }
        guard let continuation = box.value else {
            preconditionFailure("AsyncThrowingStream did not provide a continuation")
        }

        guard active[runID] == nil else {
            continuation.finish(throwing: AgentRuntimeError.alreadyRunning(runID))
            return stream
        }

        let task: Task<Void, Never> = Task { [weak self] in
            await self?.execute(
                runID: runID,
                request: request,
                snapshot: snapshot,
                continuation: continuation,
                project: project
            )
        }
        active[runID] = ActiveExecution(
            task: task,
            continuation: continuation,
            project: project
        )
        return stream
    }

    /// Moves a live run into `stopping` before cancelling the provider task. The
    /// stopping row keeps the active slot occupied until the task records the terminal
    /// `.cancelled` transition.
    func stop(runID: String) async throws {
        guard let run = try store.run(id: runID) else {
            throw AgentRuntimeError.runNotFound(runID)
        }
        guard run.state.isActive else {
            throw AgentRuntimeError.runIsNotActive(runID)
        }
        guard let execution = active[runID] else {
            throw AgentRuntimeError.runIsNotActive(runID)
        }

        if run.state != .stopping {
            try store.transitionRun(
                id: runID,
                expectedState: run.state,
                to: .stopping
            )
            do {
                try await emit(
                    .runStateChanged(runID: runID, state: .stopping),
                    continuation: execution.continuation,
                    project: execution.project
                )
            } catch {
                // A projection failure must not leave the provider alive merely
                // because the stopping notification could not be observed.
                stopRequested.insert(runID)
                execution.task.cancel()
                finishProjectionFailure(runID: runID)
                throw error
            }
        }

        stopRequested.insert(runID)
        execution.task.cancel()
    }

    /// Records an approval decision on the waiting ToolCall and wakes the suspended
    /// serial batch. The same ToolCall identity is resumed; no replacement call exists.
    func approveToolCall(toolCallID: String) throws {
        try toolRuntime.approve(toolCallID: toolCallID)
        toolDecisionWaiters.removeValue(forKey: toolCallID)?.resume()
    }

    /// Records a real model-visible rejection and wakes the suspended serial batch.
    func rejectToolCall(toolCallID: String) throws -> ToolExecutionResult {
        let result = try toolRuntime.reject(toolCallID: toolCallID)
        toolDecisionWaiters.removeValue(forKey: toolCallID)?.resume()
        return result
    }

    /// Records a post-commit failure for a path that has not reached provider
    /// streaming yet (or whose event projection failed). Run-state ownership remains
    /// here even when there is no active provider stream to carry the event.
    func fail(runID: String, endReason: EndReason) throws -> [AgentEvent] {
        guard let current = try store.run(id: runID) else {
            throw AgentRuntimeError.runNotFound(runID)
        }
        guard current.state.isActive,
              RunStateMachine.canTransition(from: current.state, to: .failed)
        else {
            return []
        }

        try store.transitionRun(
            id: runID,
            expectedState: current.state,
            to: .failed,
            endReason: endReason
        )
        return [
            .runStateChanged(runID: runID, state: .failed),
            .runEnded(runID: runID, state: .failed, endReason: endReason),
        ]
    }

    // MARK: - Execution

    private func execute(
        runID: String,
        request: ProviderChatRequest,
        snapshot: RunExecutionSnapshot,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation,
        project: @escaping AgentEventProjection
    ) async {
        let messageID = "assistant-\(runID)"
        var outputState = OutputState(
            messageID: messageID,
            partID: "part-\(runID)-\(UUID().uuidString)"
        )
        var currentRequest = request
        var isFirstProviderRequest = true
        var activeBatch: ActiveToolBatch?

        do {
            guard let initialRun = try store.run(id: runID) else {
                throw AgentRuntimeError.runNotFound(runID)
            }
            if stopRequested.contains(runID) || Task.isCancelled {
                throw ControlError.stopRequested
            }

            let entryState = initialRun.state
            if entryState == .preparing {
                try await transition(
                    runID: runID,
                    to: .requestingModel,
                    continuation: continuation,
                    project: project
                )
            }

            guard let requestingRun = try store.run(id: runID),
                  requestingRun.state == .requestingModel || requestingRun.state == .streaming
            else {
                throw ControlError.stopRequested
            }

            while true {
                if stopRequested.contains(runID) || Task.isCancelled {
                    throw ControlError.stopRequested
                }

                let durableSteps = try store.steps(inRun: runID)
                guard durableSteps.count < snapshot.maxProviderSteps else {
                    try await finishFailure(
                        runID: runID,
                        output: &outputState,
                        error: ProviderRuntimeFailure.stepLimit,
                        continuation: continuation,
                        project: project
                    )
                    break
                }

                let latestStep = durableSteps.max {
                    if $0.sequence == $1.sequence {
                        return $0.attempt < $1.attempt
                    }
                    return $0.sequence < $1.sequence
                }
                let step: AgentStepRecord
                if isFirstProviderRequest,
                   (entryState == .requestingModel || entryState == .streaming),
                   let currentStep = latestStep {
                    step = AgentStepRecord(
                        stepID: currentStep.stepID,
                        runID: runID,
                        sequence: currentStep.sequence,
                        attempt: currentStep.attempt + 1,
                        createdAt: Date()
                    )
                } else {
                    let sequence = (durableSteps.map(\.sequence).max() ?? -1) + 1
                    step = AgentStepRecord(
                        stepID: "step-\(runID)-\(sequence)",
                        runID: runID,
                        sequence: sequence,
                        attempt: 1,
                        createdAt: Date()
                    )
                }
                try store.recordStep(step)
                let identity = step.attemptIdentity
                isFirstProviderRequest = false

                if stopRequested.contains(runID) || Task.isCancelled {
                    throw ControlError.stopRequested
                }
                guard let runForRequest = try store.run(id: runID) else {
                    throw AgentRuntimeError.runNotFound(runID)
                }
                let providerStream = try await provider.stream(
                    currentRequest,
                    seed: runForRequest.requestConfigSeed,
                    credentials: credentials
                )

                var pendingToolCalls: [ProviderToolCall] = []
                var terminal = false
                var providerFinished = false

                do {
                    for try await event in providerStream {
                        if stopRequested.contains(runID) || Task.isCancelled {
                            break
                        }
                        guard try acceptsProviderOutput(runID: runID, identity: identity) else {
                            continue
                        }

                        switch event {
                        case .textDelta(let delta):
                            guard !delta.isEmpty else { continue }
                            try await ensureStreaming(
                                runID: runID,
                                continuation: continuation,
                                project: project
                            )
                            if !outputState.started {
                                try await emit(
                                    .messagePartStarted(
                                        runID: runID,
                                        messageID: outputState.messageID,
                                        partID: outputState.partID,
                                        kind: .text
                                    ),
                                    continuation: continuation,
                                    project: project
                                )
                                outputState.started = true
                            }
                            outputState.text += delta
                            if let coalesced = outputState.accumulator.append(delta) {
                                try await emit(
                                    .messagePartDelta(
                                        runID: runID,
                                        partID: outputState.partID,
                                        delta: coalesced
                                    ),
                                    continuation: continuation,
                                    project: project
                                )
                            }

                        case .reasoningDelta:
                            try await ensureStreaming(
                                runID: runID,
                                continuation: continuation,
                                project: project
                            )

                        case .toolCall(let toolCall):
                            try await ensureStreaming(
                                runID: runID,
                                continuation: continuation,
                                project: project
                            )
                            guard snapshot.modelCapabilities.contains(.tools) else {
                                try await flush(
                                    &outputState,
                                    runID: runID,
                                    continuation: continuation,
                                    project: project
                                )
                                try await transition(
                                    runID: runID,
                                    to: .toolRequested,
                                    continuation: continuation,
                                    project: project
                                )
                                try await emit(
                                    .toolCallChanged(
                                        runID: runID,
                                        toolCallID: toolCall.id,
                                        state: .validated
                                    ),
                                    continuation: continuation,
                                    project: project
                                )
                                try await finishFailure(
                                    runID: runID,
                                    output: &outputState,
                                    error: ProviderRuntimeFailure.toolsNotAvailable,
                                    continuation: continuation,
                                    project: project
                                )
                                terminal = true
                                break
                            }
                            pendingToolCalls.append(toolCall)
                            activeBatch = ActiveToolBatch(
                                calls: pendingToolCalls,
                                batchID: "batch-\(runID)-\(step.sequence)-\(step.attempt)"
                            )

                        case .finish(let reason):
                            try await ensureStreaming(
                                runID: runID,
                                continuation: continuation,
                                project: project
                            )
                            if reason == .toolCalls || !pendingToolCalls.isEmpty {
                                if pendingToolCalls.isEmpty {
                                    try await finishFailure(
                                        runID: runID,
                                        output: &outputState,
                                        error: ProviderRuntimeFailure.toolsNotAvailable,
                                        continuation: continuation,
                                        project: project
                                    )
                                    terminal = true
                                } else {
                                    providerFinished = true
                                }
                            } else {
                                try await finishSuccess(
                                    runID: runID,
                                    output: &outputState,
                                    continuation: continuation,
                                    project: project
                                )
                                terminal = true
                            }

                        case .usage:
                            continue
                        }

                        if terminal || providerFinished {
                            break
                        }
                    }
                } catch {
                    if stopRequested.contains(runID) || Task.isCancelled {
                        throw ControlError.stopRequested
                    }
                    if error is ControlError {
                        throw error
                    }
                    pendingToolCalls.removeAll()
                    try await finishFailure(
                        runID: runID,
                        output: &outputState,
                        error: error,
                        continuation: continuation,
                        project: project
                    )
                    terminal = true
                }

                if stopRequested.contains(runID) || Task.isCancelled {
                    throw ControlError.stopRequested
                }
                if terminal {
                    break
                }

                if !pendingToolCalls.isEmpty {
                    let assistantContent = outputState.text.isEmpty ? nil : outputState.text
                    activeBatch = ActiveToolBatch(
                        calls: pendingToolCalls,
                        batchID: "batch-\(runID)-\(step.sequence)-\(step.attempt)"
                    )
                    try await finishCurrentOutput(
                        &outputState,
                        runID: runID,
                        continuation: continuation,
                        project: project
                    )
                    guard let batch = activeBatch else {
                        throw ProviderRuntimeFailure.toolsNotAvailable
                    }
                    let disposition = try await processToolBatch(
                        runID: runID,
                        currentRequest: currentRequest,
                        assistantContent: assistantContent,
                        batch: batch,
                        continuation: continuation,
                        project: project
                    )
                    activeBatch = nil
                    switch disposition {
                    case .continueWith(let nextRequest):
                        currentRequest = nextRequest
                        outputState.resetPart(runID: runID)
                        continue
                    case .waitingForApproval:
                        finishStream(runID: runID, continuation: continuation)
                        return
                    }
                }

                guard try store.accepts(identity),
                      let current = try store.run(id: runID),
                      current.state == .requestingModel || current.state == .streaming
                else {
                    finishStream(runID: runID, continuation: continuation)
                    return
                }

                try await finishSuccess(
                    runID: runID,
                    output: &outputState,
                    continuation: continuation,
                    project: project
                )
                break
            }
        } catch ControlError.stopRequested {
            do {
                if let batch = activeBatch {
                    for (sequence, call) in batch.calls.enumerated() {
                        try? toolRuntime.settleForCancellation(
                            agentRunID: runID,
                            providerCallID: call.id,
                            toolID: call.name,
                            batchID: batch.batchID,
                            batchSequence: sequence
                        )
                    }
                }
                try await finishCancellation(
                    runID: runID,
                    output: &outputState,
                    continuation: continuation,
                    project: project
                )
            } catch {
                finishProjectionFailure(runID: runID)
            }
        } catch ControlError.projectionFailed {
            finishProjectionFailure(runID: runID)
        } catch {
            if stopRequested.contains(runID) || Task.isCancelled {
                do {
                    if let batch = activeBatch {
                        for (sequence, call) in batch.calls.enumerated() {
                            try? toolRuntime.settleForCancellation(
                                agentRunID: runID,
                                providerCallID: call.id,
                                toolID: call.name,
                                batchID: batch.batchID,
                                batchSequence: sequence
                            )
                        }
                    }
                    try await finishCancellation(
                        runID: runID,
                        output: &outputState,
                        continuation: continuation,
                        project: project
                    )
                } catch {
                    finishProjectionFailure(runID: runID)
                }
            } else {
                do {
                    try await finishFailure(
                        runID: runID,
                        output: &outputState,
                        error: error,
                        continuation: continuation,
                        project: project
                    )
                } catch ControlError.projectionFailed {
                    finishProjectionFailure(runID: runID)
                } catch {
                    finishProjectionFailure(runID: runID)
                }
            }
        }

        finishStream(runID: runID, continuation: continuation)
    }

    private func finishCurrentOutput(
        _ output: inout OutputState,
        runID: String,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation,
        project: @escaping AgentEventProjection
    ) async throws {
        guard output.started else { return }
        try await flush(
            &output,
            runID: runID,
            continuation: continuation,
            project: project
        )
        try await emit(
            .messagePartCompleted(
                runID: runID,
                partID: output.partID,
                state: .completed
            ),
            continuation: continuation,
            project: project
        )
        output.started = false
    }

    private func processToolBatch(
        runID: String,
        currentRequest: ProviderChatRequest,
        assistantContent: String?,
        batch: ActiveToolBatch,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation,
        project: @escaping AgentEventProjection
    ) async throws -> ToolBatchDisposition {
        try await transition(
            runID: runID,
            to: .toolRequested,
            continuation: continuation,
            project: project
        )
        try await transition(
            runID: runID,
            to: .executingTools,
            continuation: continuation,
            project: project
        )

        var completedCalls: [ToolBatchCall] = []
        var emittedCallCount = 0

        for (sequence, providerCall) in batch.calls.enumerated() {
            if stopRequested.contains(runID) || Task.isCancelled {
                throw ControlError.stopRequested
            }

            do {
                _ = try await toolRuntime.complete(
                    agentRunID: runID,
                    providerCallID: providerCall.id,
                    toolID: providerCall.name,
                    argumentsJSON: providerCall.argumentsJSON,
                    batchID: batch.batchID,
                    batchSequence: sequence
                )
            } catch ToolRuntimeError.unknownTool(_) {
                _ = try toolRuntime.rejectUnknown(
                    agentRunID: runID,
                    providerCallID: providerCall.id,
                    toolID: providerCall.name,
                    batchID: batch.batchID,
                    batchSequence: sequence
                )
            } catch {
                if stopRequested.contains(runID) || Task.isCancelled {
                    throw ControlError.stopRequested
                }

                // Validation failures occur before a ToolCall row exists. Executor
                // failures, by contrast, already have a durable failed call/result;
                // only the former need the model-visible fallback row.
                let existing = try store.toolCalls(inRun: runID).first {
                    $0.providerCallID == providerCall.id &&
                        $0.batchID == batch.batchID &&
                        $0.batchSequence == sequence
                }
                if existing == nil {
                    _ = try toolRuntime.rejectUnknown(
                        agentRunID: runID,
                        providerCallID: providerCall.id,
                        toolID: providerCall.name,
                        batchID: batch.batchID,
                        batchSequence: sequence
                    )
                }
            }

            guard let record = try store.toolCalls(inRun: runID).first(where: {
                $0.providerCallID == providerCall.id &&
                    $0.batchID == batch.batchID &&
                    $0.batchSequence == sequence
            }) else {
                throw PersistenceError.toolCallNotFound(providerCall.id)
            }
            let result = try store.toolResult(toolCallID: record.id)
            completedCalls.append(
                ToolBatchCall(
                    providerCall: providerCall,
                    record: record,
                    result: result
                )
            )

            if record.state == .waitingForApproval ||
                record.state == .waitingForSystemPermissionConsent {
                for completed in completedCalls.dropFirst(emittedCallCount) {
                    try await emit(
                        .toolCallChanged(
                            runID: runID,
                            toolCallID: completed.providerCall.id,
                            state: completed.record.state
                        ),
                        continuation: continuation,
                        project: project
                    )
                    if completed.record.state == .waitingForApproval ||
                        completed.record.state == .waitingForSystemPermissionConsent {
                        try await emit(
                            .approvalRequired(
                                runID: runID,
                                toolCallID: completed.providerCall.id
                            ),
                            continuation: continuation,
                            project: project
                        )
                    }
                }
                emittedCallCount = completedCalls.count
                try await transition(
                    runID: runID,
                    to: .waitingForApproval,
                    continuation: continuation,
                    project: project
                )
                await waitForToolDecision(toolCallID: record.id)
                if stopRequested.contains(runID) || Task.isCancelled {
                    throw ControlError.stopRequested
                }
                try await transition(
                    runID: runID,
                    to: .executingTools,
                    continuation: continuation,
                    project: project
                )

                var settledRecord = try store.toolCall(id: record.id) ?? record
                if settledRecord.state == .approved {
                    do {
                        _ = try await toolRuntime.executeApproved(toolCallID: record.id)
                    } catch {
                        if stopRequested.contains(runID) || Task.isCancelled {
                            throw ControlError.stopRequested
                        }
                    }
                    settledRecord = try store.toolCall(id: record.id) ?? settledRecord
                }
                completedCalls[completedCalls.count - 1] = ToolBatchCall(
                    providerCall: providerCall,
                    record: settledRecord,
                    result: try store.toolResult(toolCallID: settledRecord.id)
                )
                try await emit(
                    .toolCallChanged(
                        runID: runID,
                        toolCallID: providerCall.id,
                        state: settledRecord.state
                    ),
                    continuation: continuation,
                    project: project
                )
            }
        }

        for completed in completedCalls.dropFirst(emittedCallCount) {
            try await emit(
                .toolCallChanged(
                    runID: runID,
                    toolCallID: completed.providerCall.id,
                    state: completed.record.state
                ),
                continuation: continuation,
                project: project
            )
        }

        guard completedCalls.count == batch.calls.count,
              completedCalls.allSatisfy({ $0.result != nil })
        else {
            throw ProviderRuntimeFailure.toolsNotAvailable
        }

        var messages = currentRequest.messages
        messages.append(
            .assistant(
                content: assistantContent,
                reasoning: nil,
                toolCalls: batch.calls
            )
        )
        for completed in completedCalls {
            guard let result = completed.result else {
                throw ProviderRuntimeFailure.toolsNotAvailable
            }
            messages.append(
                .toolResult(
                    toolCallID: completed.providerCall.id,
                    content: result.payload
                )
            )
        }

        try await transition(
            runID: runID,
            to: .continuing,
            continuation: continuation,
            project: project
        )
        try await transition(
            runID: runID,
            to: .requestingModel,
            continuation: continuation,
            project: project
        )
        return .continueWith(
            ProviderChatRequest(
                modelID: currentRequest.modelID,
                messages: messages,
                tools: currentRequest.tools
            )
        )
    }

    private func waitForToolDecision(toolCallID: String) async {
        let call: ToolCallRecord?
        do {
            call = try store.toolCall(id: toolCallID)
        } catch {
            return
        }
        guard let call,
              call.state == .waitingForApproval ||
                call.state == .waitingForSystemPermissionConsent
        else {
            return
        }

        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                toolDecisionWaiters[toolCallID] = continuation
            }
        }, onCancel: {
            Task { await self.resumeToolDecisionWaiter(toolCallID: toolCallID) }
        })
    }

    private func resumeToolDecisionWaiter(toolCallID: String) {
        toolDecisionWaiters.removeValue(forKey: toolCallID)?.resume()
    }

    // MARK: - Event and lifecycle helpers

    private func acceptsProviderOutput(
        runID: String,
        identity: AttemptIdentity
    ) throws -> Bool {
        guard try store.accepts(identity) else { return false }
        guard let state = try store.run(id: runID)?.state else { return false }
        return state == .requestingModel || state == .streaming
    }

    private func ensureStreaming(
        runID: String,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation,
        project: @escaping AgentEventProjection
    ) async throws {
        guard let state = try store.run(id: runID)?.state else {
            throw AgentRuntimeError.runNotFound(runID)
        }
        switch state {
        case .requestingModel:
            try await transition(
                runID: runID,
                to: .streaming,
                continuation: continuation,
                project: project
            )
        case .streaming:
            return
        default:
            throw ControlError.stopRequested
        }
    }

    private func transition(
        runID: String,
        to nextState: RunState,
        endReason: EndReason? = nil,
        recoveryAction: RecoveryAction? = nil,
        suspendReason: SuspendReason? = nil,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation,
        project: @escaping AgentEventProjection
    ) async throws {
        guard let current = try store.run(id: runID) else {
            throw AgentRuntimeError.runNotFound(runID)
        }
        guard current.state != nextState else { return }
        try store.transitionRun(
            id: runID,
            expectedState: current.state,
            to: nextState,
            endReason: endReason,
            recoveryAction: recoveryAction,
            suspendReason: suspendReason
        )
        try await emit(
            .runStateChanged(runID: runID, state: nextState),
            continuation: continuation,
            project: project
        )
    }

    private func flush(
        _ output: inout OutputState,
        runID: String,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation,
        project: @escaping AgentEventProjection
    ) async throws {
        guard output.started,
              let delta = output.accumulator.flush()
        else { return }
        try await emit(
            .messagePartDelta(
                runID: runID,
                partID: output.partID,
                delta: delta
            ),
            continuation: continuation,
            project: project
        )
    }

    private func finishSuccess(
        runID: String,
        output: inout OutputState,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation,
        project: @escaping AgentEventProjection
    ) async throws {
        try await flush(
            &output,
            runID: runID,
            continuation: continuation,
            project: project
        )
        if output.started {
            try await emit(
                .messagePartCompleted(
                    runID: runID,
                    partID: output.partID,
                    state: .completed
                ),
                continuation: continuation,
                project: project
            )
        }

        guard let current = try store.run(id: runID) else {
            throw AgentRuntimeError.runNotFound(runID)
        }
        if current.state == .requestingModel {
            try await transition(
                runID: runID,
                to: .streaming,
                continuation: continuation,
                project: project
            )
        }
        guard try store.run(id: runID)?.state == .streaming else {
            throw ControlError.stopRequested
        }
        try await transition(
            runID: runID,
            to: .completed,
            endReason: .completed,
            continuation: continuation,
            project: project
        )
        try await emit(
            .runEnded(
                runID: runID,
                state: .completed,
                endReason: .completed
            ),
            continuation: continuation,
            project: project
        )
    }

    private func finishCancellation(
        runID: String,
        output: inout OutputState,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation,
        project: @escaping AgentEventProjection
    ) async throws {
        guard let current = try store.run(id: runID), current.state.isActive else { return }

        if current.state != .stopping {
            guard RunStateMachine.canTransition(from: current.state, to: .stopping) else {
                return
            }
            try await transition(
                runID: runID,
                to: .stopping,
                continuation: continuation,
                project: project
            )
        }

        try await flush(
            &output,
            runID: runID,
            continuation: continuation,
            project: project
        )
        if output.started {
            try await emit(
                .messagePartCompleted(
                    runID: runID,
                    partID: output.partID,
                    state: .cancelled
                ),
                continuation: continuation,
                project: project
            )
        }

        guard try store.run(id: runID)?.state == .stopping else { return }
        try await transition(
            runID: runID,
            to: .cancelled,
            endReason: .cancelledByUser,
            continuation: continuation,
            project: project
        )
        try await emit(
            .runEnded(
                runID: runID,
                state: .cancelled,
                endReason: .cancelledByUser
            ),
            continuation: continuation,
            project: project
        )
    }

    private func finishFailure(
        runID: String,
        output: inout OutputState,
        error: Error,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation,
        project: @escaping AgentEventProjection
    ) async throws {
        guard let current = try store.run(id: runID), current.state.isActive else { return }

        try await flush(
            &output,
            runID: runID,
            continuation: continuation,
            project: project
        )
        if output.started {
            try await emit(
                .messagePartCompleted(
                    runID: runID,
                    partID: output.partID,
                    state: .failed
                ),
                continuation: continuation,
                project: project
            )
        }

        switch failureDisposition(error: error, run: current) {
        case .failed(let reason):
            guard RunStateMachine.canTransition(from: current.state, to: .failed) else {
                return
            }
            try await transition(
                runID: runID,
                to: .failed,
                endReason: reason,
                continuation: continuation,
                project: project
            )
            try await emit(
                .runEnded(runID: runID, state: .failed, endReason: reason),
                continuation: continuation,
                project: project
            )

        case .suspended(let reason):
            guard RunStateMachine.canTransition(from: current.state, to: .suspended) else {
                return
            }
            try await transition(
                runID: runID,
                to: .suspended,
                recoveryAction: .reprepare,
                suspendReason: reason,
                continuation: continuation,
                project: project
            )
        }
    }

    private func emit(
        _ event: AgentEvent,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation,
        project: @escaping AgentEventProjection
    ) async throws {
        do {
            try await project(event)
        } catch {
            throw ControlError.projectionFailed
        }
        continuation.yield(event)
    }

    /// Projection is an acknowledgement boundary, not a best-effort observer. Once
    /// it rejects an event, stop consuming provider output and commit the failed
    /// outcome directly; emitting another event would only depend on the broken
    /// projection again.
    private func finishProjectionFailure(runID: String) {
        // Cancellation is also the provider-stream termination signal. The task may
        // be handling this error itself, but cancelling it here makes the stop
        // observable to a provider that keeps its stream continuation alive.
        active[runID]?.task.cancel()
        do {
            guard let current = try store.run(id: runID),
                  current.state.isActive,
                  RunStateMachine.canTransition(from: current.state, to: .failed)
            else { return }

            try store.transitionRun(
                id: runID,
                expectedState: current.state,
                to: .failed,
                endReason: .providerFailed
            )
        } catch {
            // The provider task still exits and releases its active slot even if a
            // concurrent lifecycle owner won the compare-and-set transition.
        }
    }

    private func failureDisposition(
        error: Error,
        run: AgentRunRecord
    ) -> FailureDisposition {
        if let failure = error as? ProviderRuntimeFailure {
            switch failure {
            case .stepLimit, .toolsNotAvailable:
                return .failed(failure.endReason)
            }
        }

        if let providerError = error as? ProviderError {
            switch providerError {
            case .streamInactivityTimeout(_, _):
                return .failed(.streamInactivityTimeout)
            case .streamInterrupted(_, _):
                return .failed(.streamInterrupted)
            case .streamProgressTimeout(_, _):
                return .failed(.stepTimeout)
            case .credentialMissing, .credentialRejected:
                return credentialDisposition(for: run)
            case .configurationMismatch(_):
                return credentialDisposition(for: run)
            case .credentialTemporarilyUnavailable(_):
                return .suspended(.networkLost)
            default:
                return .failed(.providerFailed)
            }
        }

        if let credentialError = error as? CredentialError {
            switch credentialError {
            case .authenticationRequired, .notFound:
                return .suspended(.authRequired)
            case .bindingMoved(_, _, _):
                return .failed(.credentialExpired)
            case .unavailable(_, _):
                return .suspended(.networkLost)
            case .alreadyExists, .failed(_, _):
                return .failed(.providerFailed)
            }
        }

        return .failed(.providerFailed)
    }

    private func credentialDisposition(for run: AgentRunRecord) -> FailureDisposition {
        let binding = run.requestConfigSeed.credentialBinding
        do {
            guard let metadata = try credentials.metadata(for: binding.reference) else {
                return .suspended(.authRequired)
            }
            if metadata.status == .authenticationRequired {
                return .suspended(.authRequired)
            }
            if metadata.bindingGeneration != binding.generation {
                return .failed(.credentialExpired)
            }
        } catch {
            return .failed(.providerFailed)
        }
        return .failed(.providerFailed)
    }

    private func finishStream(
        runID: String,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) {
        continuation.finish()
        active.removeValue(forKey: runID)
        stopRequested.remove(runID)
    }
}

private enum ProviderRuntimeFailure: Error {
    case stepLimit
    case toolsNotAvailable

    var endReason: EndReason {
        switch self {
        case .stepLimit: return .stepLimit
        case .toolsNotAvailable: return .providerFailed
        }
    }
}

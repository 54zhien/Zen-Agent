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
        let partID: String
        var started = false
    }

    private struct ActiveExecution {
        let task: Task<Void, Never>
        let continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
        let project: AgentEventProjection
    }

    private let store: PersistenceStore
    private let provider: any ModelProvider
    private let credentials: any CredentialStoring

    private var active: [String: ActiveExecution] = [:]
    private var stopRequested: Set<String> = []

    init(
        store: PersistenceStore,
        provider: any ModelProvider,
        credentials: any CredentialStoring
    ) {
        self.store = store
        self.provider = provider
        self.credentials = credentials
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
                throw error
            }
        }

        stopRequested.insert(runID)
        execution.task.cancel()
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
        let output = OutputState(
            messageID: messageID,
            partID: "part-\(runID)-\(UUID().uuidString)"
        )
        var outputState = output

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

            guard let requestingRun = try store.run(id: runID) else {
                throw AgentRuntimeError.runNotFound(runID)
            }
            guard requestingRun.state == .requestingModel || requestingRun.state == .streaming else {
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
                finishStream(runID: runID, continuation: continuation)
                return
            }

            let latestStep = durableSteps.max {
                if $0.sequence == $1.sequence {
                    return $0.attempt < $1.attempt
                }
                return $0.sequence < $1.sequence
            }
            let step: AgentStepRecord
            if (entryState == .requestingModel || entryState == .streaming),
               let currentStep = latestStep {
                // Re-entry while the same provider step is active is a replay of
                // that logical step. The durable step id and sequence stay stable;
                // only the provider attempt generation moves forward.
                step = AgentStepRecord(
                    stepID: currentStep.stepID,
                    runID: runID,
                    sequence: currentStep.sequence,
                    attempt: currentStep.attempt + 1,
                    createdAt: Date()
                )
            } else {
                // A preparing run is entering a new logical step. Its first
                // provider request is attempt one, even when earlier logical steps
                // already exist in the durable run.
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

            if stopRequested.contains(runID) || Task.isCancelled {
                throw ControlError.stopRequested
            }

            let providerStream = try await provider.stream(
                request,
                seed: requestingRun.requestConfigSeed,
                credentials: credentials
            )

            var receivedAcceptedEvent = false
            var reachedTerminalFinish = false

            do {
                for try await event in providerStream {
                    if stopRequested.contains(runID) || Task.isCancelled {
                        break
                    }

                    // Both checks are intentionally adjacent to the provider event.
                    // An attempt can remain current while its Run has already entered
                    // stopping, suspended or a terminal state.
                    guard try acceptsProviderOutput(runID: runID, identity: identity) else {
                        continue
                    }
                    receivedAcceptedEvent = true

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
                        // Text-only I05 does not materialise a reasoning surface. It is
                        // still provider output, so it advances the Run into streaming
                        // and is covered by the same stale-event guard.
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
                        reachedTerminalFinish = true

                    case .finish(let reason):
                        try await ensureStreaming(
                            runID: runID,
                            continuation: continuation,
                            project: project
                        )
                        if reason == .toolCalls {
                            try await finishFailure(
                                runID: runID,
                                output: &outputState,
                                error: ProviderRuntimeFailure.toolsNotAvailable,
                                continuation: continuation,
                                project: project
                            )
                        } else {
                            try await finishSuccess(
                                runID: runID,
                                output: &outputState,
                                continuation: continuation,
                                project: project
                            )
                        }
                        reachedTerminalFinish = true

                    case .usage:
                        // Usage is metadata for a later projection; it is not user
                        // content and does not create a MessagePart.
                        continue
                    }

                    if reachedTerminalFinish {
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
                try await finishFailure(
                    runID: runID,
                    output: &outputState,
                    error: error,
                    continuation: continuation,
                    project: project
                )
                reachedTerminalFinish = true
            }

            if stopRequested.contains(runID) || Task.isCancelled {
                throw ControlError.stopRequested
            }

            // The provider's stream closing is itself terminal if it did not send an
            // explicit finish event. A stale stream is the exception: it may close
            // without changing the current Run at all.
            guard try store.accepts(identity),
                  let current = try store.run(id: runID),
                  current.state == .requestingModel || current.state == .streaming
            else {
                finishStream(runID: runID, continuation: continuation)
                return
            }

            if !receivedAcceptedEvent {
                try await finishSuccess(
                    runID: runID,
                    output: &outputState,
                    continuation: continuation,
                    project: project
                )
            } else if !reachedTerminalFinish {
                try await finishSuccess(
                    runID: runID,
                    output: &outputState,
                    continuation: continuation,
                    project: project
                )
            }
        } catch ControlError.stopRequested {
            try? await finishCancellation(
                runID: runID,
                output: &outputState,
                continuation: continuation,
                project: project
            )
        } catch ControlError.projectionFailed {
            finishProjectionFailure(runID: runID)
        } catch {
            if stopRequested.contains(runID) || Task.isCancelled {
                try? await finishCancellation(
                    runID: runID,
                    output: &outputState,
                    continuation: continuation,
                    project: project
                )
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

import Foundation

enum RunRecoveryError: Error, Equatable, Sendable {
    case runNotFound(String)
    case runIsNotActive(String, RunState)
    case recoveryActionMissing(String)
}

/// Reconciles one active run from durable state after a suspend or process loss.
///
/// Recovery changes lifecycle state before it reads a checkpoint. That makes the
/// recovering state itself durable, so a second process cannot mistake an interrupted
/// recovery for an ordinary provider or tool state. The optional projection is the
/// event boundary for callers that need to restore UI state; it never owns persistence.
struct RunRecovery: Sendable {
    typealias EventProjection = @Sendable (AgentEvent) async throws -> Void

    private let store: PersistenceStore
    private let toolRuntime: ToolRuntime?
    private let credentials: (any CredentialStoring)?
    private let project: EventProjection?

    init(
        store: PersistenceStore,
        toolRuntime: ToolRuntime? = nil,
        credentials: (any CredentialStoring)? = nil,
        eventProjection: EventProjection? = nil
    ) {
        self.store = store
        self.toolRuntime = toolRuntime
        self.credentials = credentials
        self.project = eventProjection
    }

    /// Recovers only a non-terminal run. A recovery never creates a new Parent Run.
    func recover(runID: String) async throws {
        guard let initialRun = try store.run(id: runID) else {
            throw RunRecoveryError.runNotFound(runID)
        }
        guard initialRun.state.isActive else {
            throw RunRecoveryError.runIsNotActive(runID, initialRun.state)
        }

        let checkpointState = initialRun.state
        if checkpointState != .recovering {
            try store.transitionRun(
                id: runID,
                expectedState: checkpointState,
                to: .recovering,
                recoveryAction: initialRecoveryAction(for: initialRun)
            )
            try await emit(.runStateChanged(runID: runID, state: .recovering))
        }

        guard let recoveringRun = try store.run(id: runID) else {
            throw RunRecoveryError.runNotFound(runID)
        }
        guard recoveringRun.recoveryAction != nil else {
            throw RunRecoveryError.recoveryActionMissing(runID)
        }

        do {
            try validateCredentialBinding(for: recoveringRun)
        } catch {
            try await fail(runID: runID, reason: .credentialExpired)
            return
        }

        let snapshot: RunExecutionSnapshot?
        do {
            snapshot = try decodeSnapshot(for: recoveringRun)
        } catch {
            try await fail(runID: runID, reason: .unrecoverable)
            return
        }

        switch checkpointState {
        case .preparing:
            try await recoverPreparing(run: recoveringRun, snapshot: snapshot)
        case .requestingModel, .streaming:
            // No resume-token field exists in the Stage 2 snapshot. A provider POST
            // that may already have been accepted is never replayed from this path.
            try await finishInterruptedStream(run: recoveringRun)
        case .toolRequested, .executingTools:
            try await recoverToolCheckpoint(run: recoveringRun)
        case .waitingForApproval:
            try await recoverApproval(run: recoveringRun)
        case .continuing:
            guard snapshot != nil else {
                try await fail(runID: runID, reason: .unrecoverable)
                return
            }
            try await transition(runID: runID, to: .requestingModel)
        case .suspended, .recovering:
            try await recoverInferredCheckpoint(run: recoveringRun, snapshot: snapshot)
        case .stopping:
            try store.finishRun(
                id: runID,
                state: .cancelled,
                endReason: .cancelledByUser
            )
            try await emit(.runStateChanged(runID: runID, state: .cancelled))
            try await emit(
                .runEnded(
                    runID: runID,
                    state: .cancelled,
                    endReason: .cancelledByUser
                )
            )
        case .completed, .failed, .cancelled:
            // The active guard above makes this unreachable unless a concurrent writer
            // changed the row between the read and the recovery CAS.
            throw RunRecoveryError.runIsNotActive(runID, checkpointState)
        }
    }

    private func initialRecoveryAction(for run: AgentRunRecord) -> RecoveryAction {
        // `restart` remains a representable action for other product flows, but this
        // engine never selects it. A reprepare action already recorded by suspension is
        // retained; all other recoveries begin as an in-place resume.
        if run.recoveryAction == .reprepare {
            return .reprepare
        }
        return .resume
    }

    private func validateCredentialBinding(for run: AgentRunRecord) throws {
        guard let credentials else { return }

        let binding = run.requestConfigSeed.credentialBinding
        guard try credentials.resolve(
            frozenReference: binding.reference,
            generation: binding.generation
        ) != nil else {
            throw RunRecoveryError.runIsNotActive(run.id, run.state)
        }
    }

    private func decodeSnapshot(for run: AgentRunRecord) throws -> RunExecutionSnapshot? {
        guard let encodedSnapshot = run.executionSnapshot else { return nil }
        return try ExecutionSnapshotCodec.decode(encodedSnapshot)
    }

    private func recoverPreparing(
        run: AgentRunRecord,
        snapshot: RunExecutionSnapshot?
    ) async throws {
        guard snapshot != nil else {
            // No provider request has been made and no execution context is frozen, so
            // returning to preparing is the safe reprepare path. It is not a restart.
            try await transition(runID: run.id, to: .preparing)
            return
        }

        // A step is a durable provider-request identity. Seeing one while the run still
        // claims to be preparing is inconsistent with the "before provider request"
        // checkpoint and must not be guessed into a replay.
        guard try store.steps(inRun: run.id).isEmpty else {
            try await fail(runID: run.id, reason: .unrecoverable)
            return
        }
        try await transition(runID: run.id, to: .requestingModel)
    }

    private func recoverApproval(run: AgentRunRecord) async throws {
        let calls = try store.toolCalls(inRun: run.id)
            .filter { $0.state == .waitingForApproval }
        guard !calls.isEmpty else {
            try await fail(runID: run.id, reason: .unrecoverable)
            return
        }

        try await transition(runID: run.id, to: .waitingForApproval)
        for call in batchOrdered(calls) {
            try await emit(
                .approvalRequired(runID: run.id, toolCallID: call.id)
            )
        }
    }

    private func recoverToolCheckpoint(run: AgentRunRecord) async throws {
        let calls = try store.toolCalls(inRun: run.id)
        guard !calls.isEmpty else {
            try await transition(runID: run.id, to: .continuing)
            return
        }

        let uncertainCalls = calls.filter {
            $0.state == .dispatched || $0.state == .indeterminate
        }
        if !uncertainCalls.isEmpty {
            // This is intentionally the only mutation for a dispatched call. In
            // particular, `toolRuntime` is never asked to execute it again.
            for call in uncertainCalls where call.state == .dispatched {
                try store.markToolCallIndeterminate(id: call.id)
            }
            try await fail(runID: run.id, reason: .toolOutcomeUnknown)
            return
        }

        let approvalCalls = calls.filter { $0.state == .waitingForApproval }
        if !approvalCalls.isEmpty {
            try await transition(runID: run.id, to: .waitingForApproval)
            for call in batchOrdered(approvalCalls) {
                try await emit(
                    .approvalRequired(runID: run.id, toolCallID: call.id)
                )
            }
            return
        }

        let mayDispatchCalls = calls.filter {
            $0.state.recoveryDisposition == .mayDispatch
        }
        if !mayDispatchCalls.isEmpty {
            // validated/approved/prepared calls remain durable and are handed back to
            // the normal dispatch owner. Recovery itself must not cross the dispatch
            // boundary.
            try await transition(runID: run.id, to: .executingTools)
            return
        }

        if calls.contains(where: { !$0.state.isTerminal }) {
            // System-permission consent is still a user decision. Keep the run in the
            // tool phase without inventing a second approval or dispatching anything.
            try await transition(runID: run.id, to: .executingTools)
            return
        }

        // Read results in deterministic batch order. A continuation is only safe when
        // every terminal ToolCall has its durable result; no result is fabricated.
        for call in batchOrdered(calls) {
            guard try store.toolResult(toolCallID: call.id) != nil else {
                try await fail(runID: run.id, reason: .unrecoverable)
                return
            }
        }
        try await transition(runID: run.id, to: .continuing)
    }

    private func recoverInferredCheckpoint(
        run: AgentRunRecord,
        snapshot: RunExecutionSnapshot?
    ) async throws {
        let calls = try store.toolCalls(inRun: run.id)
        if !calls.isEmpty {
            try await recoverToolCheckpoint(run: run)
            return
        }

        if try hasOpenStreamingPart(in: run) {
            try await finishInterruptedStream(run: run)
            return
        }

        guard snapshot != nil else {
            try await transition(runID: run.id, to: .preparing)
            return
        }

        guard try store.steps(inRun: run.id).isEmpty else {
            try await finishInterruptedStream(run: run)
            return
        }
        try await transition(runID: run.id, to: .requestingModel)
    }

    private func finishInterruptedStream(run: AgentRunRecord) async throws {
        if let responseMessageID = run.responseMessageID {
            let parts = try store.parts(ofMessage: responseMessageID)
            for part in parts where part.state == .streaming || part.state == .pending {
                try store.finishPart(id: part.id, state: .failed)
            }
        }
        try await fail(runID: run.id, reason: .streamInterrupted)
    }

    private func hasOpenStreamingPart(in run: AgentRunRecord) throws -> Bool {
        guard let responseMessageID = run.responseMessageID else { return false }
        return try store.parts(ofMessage: responseMessageID).contains {
            $0.state == .streaming || $0.state == .pending
        }
    }

    private func transition(runID: String, to state: RunState) async throws {
        guard let current = try store.run(id: runID) else {
            throw RunRecoveryError.runNotFound(runID)
        }
        guard current.state != state else { return }
        try store.transitionRun(
            id: runID,
            expectedState: current.state,
            to: state
        )
        try await emit(.runStateChanged(runID: runID, state: state))
    }

    private func fail(runID: String, reason: EndReason) async throws {
        try store.finishRun(id: runID, state: .failed, endReason: reason)
        try await emit(.runStateChanged(runID: runID, state: .failed))
        try await emit(.runEnded(runID: runID, state: .failed, endReason: reason))
    }

    private func emit(_ event: AgentEvent) async throws {
        guard let project else { return }
        try await project(event)
    }

    private func batchOrdered(_ calls: [ToolCallRecord]) -> [ToolCallRecord] {
        calls.sorted { lhs, rhs in
            let leftBatch = lhs.batchID ?? ""
            let rightBatch = rhs.batchID ?? ""
            if leftBatch != rightBatch { return leftBatch < rightBatch }

            let leftSequence = lhs.batchSequence ?? Int.max
            let rightSequence = rhs.batchSequence ?? Int.max
            if leftSequence != rightSequence { return leftSequence < rightSequence }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id < rhs.id
        }
    }
}

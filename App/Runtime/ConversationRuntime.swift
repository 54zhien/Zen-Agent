import Foundation
import CryptoKit

indirect enum ConversationProjectionError: Error, Equatable, Sendable {
    case malformedToolCallPart(String)
    case malformedToolResultPart(String)
    case persistenceFailure(String)
    case other(String)
    case terminalizationFailed(
        primary: ConversationProjectionError,
        reason: String
    )
}

/// The Parent Send boundary.
///
/// It owns the 12-step preparation/commit order and is the only business writer for
/// Message and MessagePart rows. AgentRuntime owns Run state and sends content here as
/// AgentEvents; keeping those two write paths separate prevents a provider callback from
/// becoming an untracked database mutation.
actor ConversationRuntime {

    private let store: PersistenceStore
    private let provider: any ModelProvider
    private let credentials: any CredentialStoring
    private let agentRuntime: AgentRuntime
    private let toolRegistry: ToolRegistry
    private let onEvent: @Sendable (AgentEvent) async -> Void

    private var operations: [String: Task<Void, Never>] = [:]
    private var completionErrors: [String: ConversationProjectionError] = [:]
    private var projections: [String: RunProjection] = [:]
    private var projectionSubscribers: [
        String: [UUID: AsyncStream<RunProjection?>.Continuation]
    ] = [:]

    var activeOperationCount: Int { operations.count }

    init(
        store: PersistenceStore,
        provider: any ModelProvider,
        credentials: any CredentialStoring,
        onEvent: @escaping @Sendable (AgentEvent) async -> Void = { _ in },
        toolRegistry: ToolRegistry? = nil,
        toolRuntime: ToolRuntime? = nil
    ) {
        self.store = store
        self.provider = provider
        self.credentials = credentials
        let resolvedRegistry = toolRegistry ?? ToolRegistry.empty
        self.toolRegistry = resolvedRegistry
        self.agentRuntime = AgentRuntime(
            store: store,
            provider: provider,
            credentials: credentials,
            toolRuntime: toolRuntime ?? ToolRuntime(
                store: store,
                registry: resolvedRegistry
            )
        )
        self.onEvent = onEvent
    }

    /// Runs a Send to completion and returns the durable Parent Run id.
    func send(_ command: SendCommand) async throws -> String {
        let runID = try await start(command)
        try await waitForCompletion(runID: runID)
        return runID
    }

    /// Performs the preparation/commit boundary and starts AgentRuntime. Returning
    /// after the snapshot is committed gives callers a durable id for Stop without
    /// making the provider request itself synchronous.
    func start(_ command: SendCommand) async throws -> String {
        guard !command.submissionID.isEmpty else {
            throw ConversationRuntimeError.emptySubmissionID
        }
        let submissionDigest = Self.submissionDigest(for: command)
        if let existing = try store.run(submissionID: command.submissionID) {
            guard existing.submissionDigest == submissionDigest else {
                throw ConversationRuntimeError.submissionIDPayloadConflict(command.submissionID)
            }
            return existing.id
        }

        guard command.maxProviderSteps > 0 else {
            throw ConversationRuntimeError.invalidMaxProviderSteps(command.maxProviderSteps)
        }

        // 1. Load visible Conversation.
        guard let conversation = try store.conversation(id: command.conversationID) else {
            throw PersistenceError.conversationNotFound(command.conversationID)
        }
        guard conversation.lifecycle == .visible else {
            throw PersistenceError.invalidLifecycleTransition(
                expected: .visible,
                actual: conversation.lifecycle
            )
        }

        // 2. Load ProviderInstance.
        guard let instance = try store.providerInstance(id: command.providerInstanceID) else {
            throw PersistenceError.providerInstanceNotFound(command.providerInstanceID)
        }
        guard instance.providerID == provider.id else {
            throw ConversationRuntimeError.providerInstanceBelongsToAnotherProvider(
                instanceID: instance.id,
                expected: provider.id,
                actual: instance.providerID
            )
        }

        // 3-4. Resolve and validate the model before the first write.
        guard let descriptor = provider.descriptor(for: command.modelID, in: instance) else {
            throw ConversationRuntimeError.unsupportedModel(command.modelID)
        }
        guard descriptor.providerInstanceID == instance.id,
              descriptor.capabilities.contains(.text),
              descriptor.capabilities.contains(.streaming)
        else {
            throw ConversationRuntimeError.unsupportedTextModel(command.modelID)
        }

        // 5-6. Read metadata and freeze the exact credential binding.
        guard let reference = instance.credentialReference else {
            throw ConversationRuntimeError.missingCredential(instance.id)
        }
        guard let metadata = try credentials.metadata(for: reference) else {
            throw ConversationRuntimeError.missingCredential(instance.id)
        }
        guard metadata.status == .active else {
            throw ConversationRuntimeError.credentialUnavailable(metadata.status)
        }
        let binding = CredentialBindingSnapshot(
            reference: metadata.reference,
            generation: metadata.bindingGeneration
        )

        // 7. Provider-owned seed construction is still pre-commit.
        let seed = try provider.makeRequestConfigSeed(
            instance: instance,
            modelID: command.modelID,
            credentialBinding: binding
        )

        // 8. Build the user message, text part and preparing Parent Run.
        let messageID = "user-\(UUID().uuidString)"
        let runID = "run-\(UUID().uuidString)"
        let now = Date()
        let nextSequence = (try store.messages(inConversation: command.conversationID)
            .map(\.sequence)
            .max() ?? -1) + 1
        let userPart = MessagePartRecord(
            id: "part-\(messageID)",
            messageID: messageID,
            sequence: 0,
            kind: .text,
            state: .completed,
            payload: try PersistenceStore.encodeTextPayload(
                .init(text: command.text)
            )
        )
        let userMessage = MessageRecord(
            id: messageID,
            conversationID: command.conversationID,
            role: .user,
            sequence: nextSequence,
            createdAt: now
        )
        let run = AgentRunRecord(
            id: runID,
            conversationID: command.conversationID,
            kind: .parent,
            parentRunID: nil,
            state: .preparing,
            endReason: nil,
            recoveryAction: nil,
            suspendReason: nil,
            triggerMessageID: messageID,
            responseMessageID: nil,
            retryOfRunID: nil,
            requestConfigSeed: seed,
            executionSnapshot: nil,
            createdAt: now,
            updatedAt: now,
            activeSlot: nil,
            submissionID: command.submissionID,
            submissionDigest: submissionDigest
        )

        // 9. The only send commit. The store transaction makes steps 8-9 all-or-none.
        if let existingRunID = try store.commitUserTurnAndCreateParentRun(
            SendCommit(
                conversation: conversation,
                message: userMessage,
                parts: [userPart],
                run: run
            )
        ) {
            return existingRunID
        }

        // 10. From this point on the Run is a real business object.
        await publish(.runAccepted(
            runID: runID,
            conversationID: command.conversationID
        ))

        // 11. Freeze the non-secret execution boundary exactly once.
        let snapshot = RunExecutionSnapshot(
            providerID: provider.id,
            providerAdapterRevision: provider.adapterRevision,
            prompt: PromptExecutionSnapshot(
                runtimeSafetyBaseline: "runtime-safety-v1",
                zenCore: "zen-core-v1",
                providerAdapterInstructions: provider.adapterPromptInstructions
            ),
            modelCapabilities: descriptor.capabilities,
            exposedTools: toolRegistry.descriptors.map {
                ToolExposureSnapshot(
                    toolID: $0.id,
                    descriptorRevision: $0.revision,
                    displayName: $0.displayName,
                    description: $0.description,
                    inputSchema: $0.inputSchema
                )
            },
            maxProviderSteps: command.maxProviderSteps
        )
        do {
            try store.completeExecutionSnapshot(
                runID: runID,
                encodedSnapshot: try ExecutionSnapshotCodec.encode(snapshot),
                at: now
            )
        } catch {
            // The commit already happened, so this is a failed Run rather than a
            // failed Send preparation. Never turn a durable user message into a
            // phantom by surfacing it as if no business object existed.
            let failureEvents = (try? await agentRuntime.fail(
                runID: runID,
                endReason: .providerFailed
            )) ?? []
            await publishFailureEvents(failureEvents)
            return runID
        }

        // 12. Only now may AgentRuntime advance the Run into provider execution.
        let request = ProviderChatRequest(
            modelID: command.modelID,
            messages: [.user(command.text)],
            tools: toolRegistry.descriptors.map {
                ProviderToolDefinition(
                    name: $0.id,
                    description: $0.description,
                    parameters: $0.inputSchema
                )
            }
        )
        let agent = agentRuntime
        let stream = await agent.advance(
            runID: runID,
            request: request,
            snapshot: snapshot,
            // The projection owns the durability acknowledgement. Keep this
            // runtime alive until the active execution has either applied or
            // rejected every event; a vanished weak observer cannot acknowledge
            // durable content.
            project: { event in
                try await self.applyAndPublish(event)
            }
        )
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.consume(runID: runID, stream: stream)
            await self.removeCompletedOperation(runID: runID)
        }
        operations[runID] = task
        return runID
    }

    /// Waits for the AgentRuntime stream to reach its durable outcome. Provider errors
    /// are intentionally not thrown here: they are already represented by Run.state
    /// and Run.endReason. Projection and settlement diagnostics are different: the
    /// caller needs to observe the durable failure category instead of receiving a
    /// successful return for a Run whose event stream failed.
    func waitForCompletion(runID: String) async throws {
        guard let task = operations[runID] else {
            if let error = completionErrors.removeValue(forKey: runID) {
                throw error
            }
            if let run = try store.run(id: runID), run.state.isTerminal {
                return
            }
            throw AgentRuntimeError.runNotFound(runID)
        }
        await task.value
        if let error = completionErrors.removeValue(forKey: runID) {
            throw error
        }
    }

    /// Requests Stop through AgentRuntime. That owner first records `stopping`; the
    /// terminal transition and active-slot release happen only after cancellation has
    /// flushed the open part.
    func stop(runID: String) async throws {
        if let events = try await agentRuntime.cancelTasklessSuspendedRun(runID: runID) {
            for event in events {
                try await applyAndPublish(event)
            }
            return
        }
        try await agentRuntime.stop(runID: runID)
    }

    func knownModels(for providerInstanceID: ProviderInstanceID) throws -> [ModelDescriptor] {
        guard let instance = try store.providerInstance(id: providerInstanceID) else {
            throw PersistenceError.providerInstanceNotFound(providerInstanceID)
        }
        guard instance.providerID == provider.id else {
            throw ConversationRuntimeError.providerInstanceBelongsToAnotherProvider(
                instanceID: instance.id,
                expected: provider.id,
                actual: instance.providerID
            )
        }
        return provider.knownModels(for: instance).filter {
            $0.providerInstanceID == providerInstanceID
        }
    }

    func projection(conversationID: String) throws -> RunProjection? {
        if let run = try store.activeParentRuns(inConversation: conversationID).first {
            let projection = RunProjection(runID: run.id, state: run.state)
            projections[conversationID] = projection
            return projection
        }
        if let cached = projections[conversationID],
           let persisted = try store.run(id: cached.runID) {
            let projection = RunProjection(runID: persisted.id, state: persisted.state)
            projections[conversationID] = projection
            return projection
        }
        return projections[conversationID]
    }

    func projectionUpdates(conversationID: String) -> AsyncStream<RunProjection?> {
        let subscriptionID = UUID()
        let (stream, continuation) = AsyncStream<RunProjection?>.makeStream()
        projectionSubscribers[conversationID, default: [:]][subscriptionID] = continuation
        continuation.yield(try? projection(conversationID: conversationID))
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeProjectionSubscriber(
                    conversationID: conversationID,
                    subscriptionID: subscriptionID
                )
            }
        }
        return stream
    }

    /// Resolves an approval gate without creating a replacement ToolCall.
    func approve(toolCallID: String) async throws {
        try await agentRuntime.approveToolCall(toolCallID: toolCallID)
    }

    /// Persists a real rejection and lets the waiting batch continue in order.
    func reject(toolCallID: String) async throws -> ToolExecutionResult {
        try await agentRuntime.rejectToolCall(toolCallID: toolCallID)
    }

    // MARK: - AgentEvent projection

    private func consume(
        runID: String,
        stream: AsyncThrowingStream<AgentEvent, Error>
    ) async {
        do {
            // AgentRuntime awaits the projection callback before it advances its
            // lifecycle. This loop only drains the public event stream so the
            // caller-facing stream remains live; applying here would reintroduce
            // the terminal-state race that the acknowledgement boundary closes.
            for try await _ in stream { }
        } catch let error as ConversationProjectionError {
            completionErrors[runID] = error
            await failCommittedRun(runID: runID)
        } catch let error as AgentRuntimeError {
            if case .cancellationSettlementFailed = error {
                // A settlement error is not a provider business outcome. Keep it
                // visible even when another lifecycle owner already made the Run
                // terminal; failCommittedRun only changes active Runs.
                completionErrors[runID] = .other(
                    "tool cancellation settlement failed: \(String(describing: error))"
                )
            }
            await failCommittedRun(runID: runID)
        } catch {
            await failCommittedRun(runID: runID)
        }
    }

    private func applyAndPublish(_ event: AgentEvent) async throws {
        do {
            try apply(event)
        } catch let error as ConversationProjectionError {
            completionErrors[runID(from: event)] = error
            throw error
        } catch {
            let diagnostic = ConversationProjectionError.persistenceFailure(
                String(describing: error)
            )
            completionErrors[runID(from: event)] = diagnostic
            throw diagnostic
        }
        await publish(event)
    }

    private func apply(_ event: AgentEvent) throws {
        switch event {
        case .messagePartStarted(
            _,
            let messageID,
            let partID,
            let kind
        ):
            let response = try store.ensureAssistantResponse(
                forRunID: runID(from: event),
                messageID: messageID
            )
            let nextSequence = (try store.parts(ofMessage: response.id)
                .map(\.sequence)
                .max() ?? -1) + 1
            let part = MessagePartRecord(
                id: partID,
                messageID: response.id,
                sequence: nextSequence,
                kind: kind,
                state: .streaming,
                payload: try PersistenceStore.encodeTextPayload(.init(text: ""))
            )
            try store.createPart(part)

        case .messagePartDelta(_, let partID, let delta):
            try store.appendText(toPart: partID, delta: delta)

        case .messagePartCompleted(_, let partID, let state):
            try store.finishPart(id: partID, state: state)

        case .toolCallChanged(let runID, let providerCallID, _):
            try materializeToolParts(runID: runID, providerCallID: providerCallID)

        case .runAccepted,
             .runStateChanged,
             .approvalRequired,
             .runEnded:
            break
        }
    }

    /// Tool message parts deliberately carry only the durable ToolCall identity.
    /// The ToolCall and ToolResult rows remain the source of truth for state and body.
    private func materializeToolParts(runID: String, providerCallID: String) throws {
        guard let run = try store.run(id: runID) else {
            throw PersistenceError.runNotFound(runID)
        }
        let response = try store.ensureAssistantResponse(
            forRunID: runID,
            messageID: run.responseMessageID ?? "assistant-\(runID)"
        )
        guard let call = try store.toolCalls(inRun: runID).first(where: {
            $0.providerCallID == providerCallID || $0.id == providerCallID
        }) else { return }

        let callsInBatch: [ToolCallRecord]
        if let batchID = call.batchID {
            callsInBatch = try store.toolCalls(inRun: runID).filter { $0.batchID == batchID }
                .sorted { ($0.batchSequence ?? 0) < ($1.batchSequence ?? 0) }
        } else {
            callsInBatch = [call]
        }

        for batchCall in callsInBatch {
            let reference = batchCall.id
            let parts = try store.parts(ofMessage: response.id)
            var hasCallPart = false
            for part in parts where part.kind == .toolCall {
                if try decodeToolCallPayload(part.payload, partID: part.id).toolCallID == reference {
                    hasCallPart = true
                    break
                }
            }
            if !hasCallPart {
                try store.createPart(
                    MessagePartRecord(
                        id: "tool-call-\(runID)-\(batchCall.id)",
                        messageID: response.id,
                        sequence: nextPartSequence(messageID: response.id),
                        kind: .toolCall,
                        state: .completed,
                        payload: try encodeToolCallPayload(
                            ToolCallPartPayload(toolCallID: reference)
                        )
                    )
                )
            }
        }

        guard try store.toolResult(toolCallID: call.id) != nil else { return }
        let reference = call.id
        var hasResultPart = false
        let parts = try store.parts(ofMessage: response.id)
        for part in parts where part.kind == .toolResult {
            if try decodeToolResultPayload(part.payload, partID: part.id).toolCallID == reference {
                hasResultPart = true
                break
            }
        }
        guard !hasResultPart else { return }
        try store.createPart(
            MessagePartRecord(
                id: "tool-result-\(runID)-\(call.id)",
                messageID: response.id,
                sequence: nextPartSequence(messageID: response.id),
                kind: .toolResult,
                state: .completed,
                payload: try encodeToolResultPayload(
                    ToolResultPartPayload(toolCallID: reference)
                )
            )
        )
    }

    private func nextPartSequence(messageID: String) throws -> Int {
        (try store.parts(ofMessage: messageID).map(\.sequence).max() ?? -1) + 1
    }

    private func encodeToolCallPayload(_ payload: ToolCallPartPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }

    private func decodeToolCallPayload(
        _ payload: String,
        partID: String
    ) throws -> ToolCallPartPayload {
        do {
            return try JSONDecoder().decode(
                ToolCallPartPayload.self,
                from: Data(payload.utf8)
            )
        } catch {
            throw ConversationProjectionError.malformedToolCallPart(partID)
        }
    }

    private func encodeToolResultPayload(_ payload: ToolResultPartPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }

    private func decodeToolResultPayload(
        _ payload: String,
        partID: String
    ) throws -> ToolResultPartPayload {
        do {
            return try JSONDecoder().decode(
                ToolResultPartPayload.self,
                from: Data(payload.utf8)
            )
        } catch {
            throw ConversationProjectionError.malformedToolResultPart(partID)
        }
    }

    private func runID(from event: AgentEvent) -> String {
        switch event {
        case .runAccepted(let runID, _),
             .runStateChanged(let runID, _),
             .messagePartStarted(let runID, _, _, _),
             .messagePartDelta(let runID, _, _),
             .messagePartCompleted(let runID, _, _),
             .toolCallChanged(let runID, _, _),
             .approvalRequired(let runID, _),
             .runEnded(let runID, _, _):
            return runID
        }
    }

    private func failCommittedRun(runID: String) async {
        do {
            let failureEvents = try await agentRuntime.fail(
                runID: runID,
                endReason: .providerFailed
            )
            await publishFailureEvents(failureEvents)
        } catch let error {
            if let existing = completionErrors[runID] {
                if case .terminalizationFailed = existing {
                    return
                }
            }
            let primary = completionErrors[runID] ?? .other(
                "the AgentRuntime stream failed before it could record a projection diagnostic"
            )
            completionErrors[runID] = .terminalizationFailed(
                primary: primary,
                reason: String(describing: error)
            )
        }
    }

    private func publishFailureEvents(_ events: [AgentEvent]) async {
        for event in events {
            await publish(event)
        }
    }

    private func publish(_ event: AgentEvent) async {
        publishProjection(for: event)
        await onEvent(event)
    }

    private func publishProjection(for event: AgentEvent) {
        let eventRunID = runID(from: event)
        let conversationID: String
        if case .runAccepted(_, let acceptedConversationID) = event {
            conversationID = acceptedConversationID
        } else if let run = try? store.run(id: eventRunID) {
            conversationID = run.conversationID
        } else {
            return
        }

        var projection: RunProjection
        if var current = projections[conversationID], current.runID == eventRunID {
            current.apply(event)
            projection = current
        } else if let initial = RunProjection(event: event) {
            projection = initial
        } else if let run = try? store.run(id: eventRunID) {
            projection = RunProjection(runID: eventRunID, state: run.state)
        } else {
            return
        }

        guard projections[conversationID] != projection else { return }
        projections[conversationID] = projection
        if let continuations = projectionSubscribers[conversationID]?.values {
            for continuation in continuations {
                continuation.yield(projection)
            }
        }
    }

    private func removeProjectionSubscriber(
        conversationID: String,
        subscriptionID: UUID
    ) {
        projectionSubscribers[conversationID]?.removeValue(forKey: subscriptionID)
        if projectionSubscribers[conversationID]?.isEmpty == true {
            projectionSubscribers.removeValue(forKey: conversationID)
        }
    }

    private func removeCompletedOperation(runID: String) {
        operations.removeValue(forKey: runID)
    }

    private static func submissionDigest(for command: SendCommand) -> String {
        let components = [
            command.conversationID,
            command.text,
            command.providerInstanceID.rawValue,
            command.modelID.rawValue,
            String(command.maxProviderSteps),
        ]
        var encoded = Data()
        for component in components {
            let bytes = Data(component.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { encoded.append(contentsOf: $0) }
            encoded.append(bytes)
        }
        return SHA256.hash(data: encoded)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

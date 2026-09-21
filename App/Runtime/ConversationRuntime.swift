import Foundation

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
    private let onEvent: @Sendable (AgentEvent) async -> Void

    private var operations: [String: Task<Void, Never>] = [:]

    init(
        store: PersistenceStore,
        provider: any ModelProvider,
        credentials: any CredentialStoring,
        onEvent: @escaping @Sendable (AgentEvent) async -> Void = { _ in }
    ) {
        self.store = store
        self.provider = provider
        self.credentials = credentials
        self.agentRuntime = AgentRuntime(
            store: store,
            provider: provider,
            credentials: credentials
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
            activeSlot: nil
        )

        // 9. The only send commit. The store transaction makes steps 8-9 all-or-none.
        try store.commitUserTurnAndCreateParentRun(
            SendCommit(
                conversation: conversation,
                message: userMessage,
                parts: [userPart],
                run: run
            )
        )

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
            exposedTools: [],
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
            operations[runID] = Task<Void, Never> {}
            return runID
        }

        // 12. Only now may AgentRuntime advance the Run into provider execution.
        let request = ProviderChatRequest(
            modelID: command.modelID,
            messages: [.user(command.text)]
        )
        let agent = agentRuntime
        let stream = await agent.advance(
            runID: runID,
            request: request,
            snapshot: snapshot
        )
        let task: Task<Void, Never> = Task { [weak self] in
            await self?.consume(runID: runID, stream: stream)
        }
        operations[runID] = task
        return runID
    }

    /// Waits for the AgentRuntime stream to reach its durable outcome. Provider errors
    /// are intentionally not thrown here: they are already represented by Run.state
    /// and Run.endReason.
    func waitForCompletion(runID: String) async throws {
        guard let task = operations[runID] else {
            if let run = try store.run(id: runID), run.state.isTerminal {
                return
            }
            throw AgentRuntimeError.runNotFound(runID)
        }
        await task.value
        operations.removeValue(forKey: runID)
    }

    /// Requests Stop through AgentRuntime. That owner first records `stopping`; the
    /// terminal transition and active-slot release happen only after cancellation has
    /// flushed the open part.
    func stop(runID: String) async throws {
        try await agentRuntime.stop(runID: runID)
    }

    // MARK: - AgentEvent projection

    private func consume(
        runID: String,
        stream: AsyncThrowingStream<AgentEvent, Error>
    ) async {
        do {
            for try await event in stream {
                try apply(event)
                await publish(event)
            }
        } catch {
            await failCommittedRun(runID: runID)
        }
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

        case .runAccepted,
             .runStateChanged,
             .toolCallChanged,
             .approvalRequired,
             .runEnded:
            break
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
        let failureEvents = (try? await agentRuntime.fail(
            runID: runID,
            endReason: .providerFailed
        )) ?? []
        await publishFailureEvents(failureEvents)
    }

    private func publishFailureEvents(_ events: [AgentEvent]) async {
        for event in events {
            await publish(event)
        }
    }

    private func publish(_ event: AgentEvent) async {
        await onEvent(event)
    }
}

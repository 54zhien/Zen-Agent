import Foundation

enum RunRequestRebuildError: Error, Sendable {
    case missingDependency
    case incompleteCommittedInput
    case incompatibleSnapshot
}

struct RecoveredToolBatch: Sendable {
    let requestBeforeBatch: ProviderChatRequest
    let calls: [ToolCallRecord]
    let providerCalls: [ProviderToolCall]
    let assistantContent: String?
}

struct ToolCallProtocolTranscript: Codable, Sendable {
    static let currentVersion = 1

    let version: Int
    let assistantContent: String?
    let calls: [Call]

    struct Call: Codable, Sendable {
        let id: String
        let index: Int
        let name: String
        let argumentsJSON: String

        init(_ call: ProviderToolCall) {
            id = call.id
            index = call.index
            name = call.name
            argumentsJSON = call.argumentsJSON
        }

        var providerCall: ProviderToolCall {
            ProviderToolCall(id: id, index: index, name: name, argumentsJSON: argumentsJSON)
        }
    }

    init(assistantContent: String?, calls: [ProviderToolCall]) {
        version = Self.currentVersion
        self.assistantContent = assistantContent
        self.calls = calls.map(Call.init)
    }
}

/// Rebuilds a request only from the original committed input and frozen execution
/// identity. The caller supplies eligible prior history; mutable Draft and current
/// Soul selection never enter this boundary.
struct RunRequestRebuilder {
    let store: PersistenceStore
    let provider: any ModelProvider
    let toolRegistry: ToolRegistry
    let credentials: (any CredentialStoring)?
    let availableMCPServerIDs: Set<String>?
    let availableMCPServerIdentities: [String: MCPServerDependencyIdentity]?

    init(store: PersistenceStore, provider: any ModelProvider, toolRegistry: ToolRegistry,
         credentials: (any CredentialStoring)? = nil, availableMCPServerIDs: Set<String>? = nil,
         availableMCPServerIdentities: [String: MCPServerDependencyIdentity]? = nil) {
        self.store = store; self.provider = provider; self.toolRegistry = toolRegistry; self.credentials = credentials
        self.availableMCPServerIDs = availableMCPServerIDs
        self.availableMCPServerIdentities = availableMCPServerIdentities
    }

    func initialRequest(
        for run: AgentRunRecord,
        snapshot: RunExecutionSnapshot,
        history: [PromptHistoryMessage]
    ) throws -> ProviderChatRequest {
        guard snapshot.providerID == provider.id,
              snapshot.providerAdapterRevision == provider.adapterRevision,
              snapshot.maxProviderSteps > 0
        else { throw RunRequestRebuildError.incompatibleSnapshot }

        guard let instance = try store.providerInstance(
            id: run.requestConfigSeed.providerInstanceID
        ), instance.providerID == provider.id
        else { throw RunRequestRebuildError.missingDependency }

        let currentTools = toolRegistry.descriptors.map {
            ToolExposureSnapshot(
                toolID: $0.id,
                descriptorRevision: $0.revision,
                displayName: $0.displayName,
                description: $0.description,
                inputSchema: $0.inputSchema
            )
        }
        // The registry may gain tools after this Run was frozen. Only the original
        // exposures are eligible for this request, and each must still match.
        guard snapshot.exposedTools.allSatisfy({ currentTools.contains($0) }) else {
            throw RunRequestRebuildError.missingDependency
        }

        guard let triggerID = run.triggerMessageID,
              let trigger = try store.messages(inConversation: run.conversationID)
                .first(where: { $0.id == triggerID && $0.role == .user })
        else { throw RunRequestRebuildError.incompleteCommittedInput }
        let parts = try store.parts(ofMessage: trigger.id)
        guard !parts.isEmpty,
              parts.allSatisfy({ $0.kind == .text && $0.state == .completed }),
              try store.attachments(forMessage: trigger.id).isEmpty
        else { throw RunRequestRebuildError.incompleteCommittedInput }
        let userText = try parts.map {
            try PersistenceStore.decodeTextPayload($0.payload).text
        }.joined()
        let quotes = try store.quoteReferences(forMessageID: trigger.id).map(\.snapshot)

        let soulInstructions: String?
        if let versionID = snapshot.prompt.soulVersionID {
            guard let version = try store.soulVersion(id: versionID) else {
                throw RunRequestRebuildError.missingDependency
            }
            soulInstructions = version.instructions
        } else {
            soulInstructions = nil
        }
        let sections = try PromptTemplateCatalog.resolve(
            runtimeSafetyRevision: snapshot.prompt.runtimeSafetyBaseline,
            zenCoreRevision: snapshot.prompt.zenCore
        )
        let memory = try store.resolveMemoryReferences(snapshot.prompt.memoryReferences)
        let skills: [SkillContext]
        do {
            try store.validateExtensionDependencies(runID: run.id, snapshot: snapshot)
            if snapshot.prompt.skillReferences.isEmpty { skills = [] }
            else {
                guard let credentials else { throw RunRequestRebuildError.missingDependency }
                skills = try SkillRuntime(
                    store: store,
                    credentials: credentials,
                    registry: toolRegistry,
                    availableMCPServerIDs: availableMCPServerIDs,
                    availableMCPServerIdentities: availableMCPServerIdentities,
                    frozenMCPServerDependencies: snapshot.mcpServerDependencies
                )
                    .resolveFrozen(snapshot.prompt.skillReferences)
            }
        } catch { throw RunRequestRebuildError.missingDependency }
        return PromptComposer().compose(PromptCompositionInput(
            modelID: run.requestConfigSeed.modelID,
            providerAdapterInstructions: snapshot.prompt.providerAdapterInstructions,
            history: history,
            currentUserMessage: userText,
            currentUserQuotedSnapshots: quotes,
            soulInstructions: soulInstructions,
            relevantMemories: memory.map(\.content),
            activatedSkills: skills,
            tools: snapshot.exposedTools.map {
                ProviderToolDefinition(
                    name: $0.toolID,
                    description: $0.description,
                    parameters: $0.inputSchema
                )
            },
            systemSections: sections
        ))
    }

    func latestToolBatch(
        for run: AgentRunRecord,
        snapshot: RunExecutionSnapshot,
        history: [PromptHistoryMessage]
    ) throws -> RecoveredToolBatch {
        let request = try initialRequest(for: run, snapshot: snapshot, history: history)
        let steps = try store.steps(inRun: run.id)
        let calls = try store.toolCalls(inRun: run.id)
        guard !steps.isEmpty, !calls.isEmpty else {
            throw RunRequestRebuildError.incompleteCommittedInput
        }

        if steps.count == 1 {
            guard let step = steps.first,
                  step.sequence == 0,
                  step.attempt == 1
            else { throw RunRequestRebuildError.incompleteCommittedInput }
            return try latestSingleStepToolBatch(
                run: run,
                step: step,
                calls: calls.sorted { ($0.batchSequence ?? Int.max) < ($1.batchSequence ?? Int.max) },
                request: request,
                snapshot: snapshot
            )
        }

        // Cold recovery currently supports only complete, first-attempt tool rounds.
        // An interrupted Provider request remains governed by the existing recovery path.
        guard steps.enumerated().allSatisfy({
            $0.element.sequence == $0.offset && $0.element.attempt == 1
        }) else { throw RunRequestRebuildError.incompleteCommittedInput }

        var messages = request.messages
        var expectedCallCount = 0
        var latestBatch: RecoveredToolBatch?

        for (stepIndex, step) in steps.enumerated() {
            let batchID = "batch-\(run.id)-\(step.sequence)-\(step.attempt)"
            guard let encodedTranscript = step.protocolResponse,
                  let transcript = try? JSONDecoder().decode(
                    ToolCallProtocolTranscript.self,
                    from: Data(encodedTranscript.utf8)
                  ),
                  transcript.version == ToolCallProtocolTranscript.currentVersion,
                  !transcript.calls.isEmpty
            else { throw RunRequestRebuildError.incompleteCommittedInput }

            let batchCalls = calls.filter { $0.batchID == batchID }.sorted {
                ($0.batchSequence ?? Int.max) < ($1.batchSequence ?? Int.max)
            }
            guard batchCalls.count == transcript.calls.count else {
                throw RunRequestRebuildError.incompleteCommittedInput
            }

            var providerCalls: [ProviderToolCall] = []
            for (index, pair) in zip(batchCalls, transcript.calls).enumerated() {
                let (call, protocolCall) = pair
                guard call.batchID == batchID,
                      call.batchSequence == index,
                      let providerCallID = call.providerCallID,
                      providerCallID == protocolCall.id,
                      call.action == protocolCall.name
                else { throw RunRequestRebuildError.incompleteCommittedInput }
                if stepIndex == steps.count - 1 {
                    _ = try validatedIntent(for: call, snapshot: snapshot)
                }
                providerCalls.append(protocolCall.providerCall)
            }

            expectedCallCount += batchCalls.count
            if stepIndex == steps.count - 1 {
                latestBatch = RecoveredToolBatch(
                    requestBeforeBatch: ProviderChatRequest(
                        modelID: request.modelID,
                        messages: messages,
                        tools: request.tools
                    ),
                    calls: batchCalls,
                    providerCalls: providerCalls,
                    assistantContent: transcript.assistantContent
                )
            } else {
                messages.append(.assistant(
                    content: transcript.assistantContent,
                    reasoning: nil,
                    toolCalls: providerCalls
                ))
                for (call, protocolCall) in zip(batchCalls, providerCalls) {
                    guard call.state.isTerminal,
                          let result = try store.toolResult(toolCallID: call.id)
                    else { throw RunRequestRebuildError.incompleteCommittedInput }
                    messages.append(.toolResult(
                        toolCallID: protocolCall.id,
                        content: result.payload
                    ))
                }
            }
        }

        guard expectedCallCount == calls.count, let latestBatch else {
            throw RunRequestRebuildError.incompleteCommittedInput
        }
        return latestBatch
    }

    private func latestSingleStepToolBatch(
        run: AgentRunRecord,
        step: AgentStepRecord,
        calls: [ToolCallRecord],
        request: ProviderChatRequest,
        snapshot: RunExecutionSnapshot
    ) throws -> RecoveredToolBatch {
        let batchID = "batch-\(run.id)-\(step.sequence)-\(step.attempt)"
        var providerCalls: [ProviderToolCall] = []
        for (index, call) in calls.enumerated() {
            let intent = try validatedIntent(for: call, snapshot: snapshot)
            guard call.batchID == batchID,
                  call.batchSequence == index,
                  let providerCallID = call.providerCallID
            else { throw RunRequestRebuildError.incompleteCommittedInput }
            providerCalls.append(ProviderToolCall(
                id: providerCallID,
                index: index,
                name: call.action,
                argumentsJSON: intent.normalizedArgumentsJSON
            ))
        }

        var assistantContent: String?
        if let responseID = run.responseMessageID {
            let parts = try store.parts(ofMessage: responseID)
            let textParts = parts.filter { $0.kind == .text }
            guard textParts.allSatisfy({ $0.state == .completed }) else {
                throw RunRequestRebuildError.incompleteCommittedInput
            }
            let text = try textParts.map {
                try PersistenceStore.decodeTextPayload($0.payload).text
            }.joined()
            assistantContent = text.isEmpty ? nil : text
        }

        return RecoveredToolBatch(
            requestBeforeBatch: request,
            calls: calls,
            providerCalls: providerCalls,
            assistantContent: assistantContent
        )
    }

    private func validatedIntent(
        for call: ToolCallRecord,
        snapshot: RunExecutionSnapshot
    ) throws -> ToolExecutionIntent {
        guard let encodedIntent = call.executionIntent,
              let intent = try? ToolIntentCodec.decodeForDisplay(encodedIntent),
              intent.toolID == call.action,
              snapshot.exposedTools.contains(where: {
                $0.toolID == intent.toolID &&
                    $0.descriptorRevision == intent.descriptorRevision
              })
        else { throw RunRequestRebuildError.incompleteCommittedInput }
        return intent
    }
}

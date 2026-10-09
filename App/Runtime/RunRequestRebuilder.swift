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

/// Rebuilds a request only from the original committed input and frozen execution
/// identity. The caller supplies eligible prior history; mutable Draft and current
/// Soul selection never enter this boundary.
struct RunRequestRebuilder {
    let store: PersistenceStore
    let provider: any ModelProvider
    let toolRegistry: ToolRegistry

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
        return PromptComposer().compose(PromptCompositionInput(
            modelID: run.requestConfigSeed.modelID,
            providerAdapterInstructions: snapshot.prompt.providerAdapterInstructions,
            history: history,
            currentUserMessage: userText,
            currentUserQuotedSnapshots: quotes,
            soulInstructions: soulInstructions,
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
        // Older protocol rounds are not durably representable in this schema. Do not
        // produce a continuation that silently drops one from the model transcript.
        guard steps.count == 1,
              let step = steps.first,
              step.sequence == 0,
              step.attempt == 1
        else { throw RunRequestRebuildError.incompleteCommittedInput }

        let calls = try store.toolCalls(inRun: run.id).sorted {
            ($0.batchSequence ?? Int.max) < ($1.batchSequence ?? Int.max)
        }
        guard !calls.isEmpty else { throw RunRequestRebuildError.incompleteCommittedInput }
        var providerCalls: [ProviderToolCall] = []
        for (index, call) in calls.enumerated() {
            guard call.batchID == "batch-\(run.id)-\(step.sequence)-\(step.attempt)",
                  call.batchSequence == index,
                  let providerCallID = call.providerCallID,
                  let encodedIntent = call.executionIntent,
                  let intent = try? ToolIntentCodec.decodeForDisplay(encodedIntent),
                  intent.toolID == call.action,
                  snapshot.exposedTools.contains(where: {
                    $0.toolID == intent.toolID &&
                        $0.descriptorRevision == intent.descriptorRevision
                  })
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
}

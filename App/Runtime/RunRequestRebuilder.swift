import Foundation

enum RunRequestRebuildError: Error, Sendable {
    case missingDependency
    case incompleteCommittedInput
    case incompatibleSnapshot
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
        ), instance.providerID == provider.id,
            instance.credentialReference == run.requestConfigSeed.credentialBinding.reference
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
        guard currentTools == snapshot.exposedTools else {
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
}

import Foundation
import Testing
@testable import ZenAgent

@Suite("Stage8 Skills cannot expand frozen Tool exposure")
struct SkillAuthorityTests {
    @Test("a recovered Run cannot gain a newly registered Tool outside its original frozen exposure", .timeLimit(.minutes(1)))
    func addedRegistryToolDoesNotExpandRecoveredExposure() async throws {
        let effects = SideEffectLedger()
        let tool = Stage2SideEffectTool(ledger: effects)
        let fixture = try MemoryPromptFixture.make(scripts: [
            .events([.toolCall(.init(id: "unexposed-new-tool", index: 0, name: tool.descriptor.id, argumentsJSON: "{}")), .finish(.toolCalls)]),
            .events([.textDelta("Finished"), .finish(.stop)])
        ])
        let storedInstance = try fixture.store.providerInstance(id: fixture.instanceID)
        let instance = try #require(storedInstance)
        let reference = try #require(instance.credentialReference)
        let storedMetadata = try fixture.credentials.metadata(for: reference)
        let metadata = try #require(storedMetadata)
        let descriptor = try #require(fixture.provider.descriptor(for: Stage2GateFixture.modelID, in: instance))
        var commit = Fixtures.send(messageID: "frozen-exposure-user", runID: "frozen-exposure-run")
        commit.run.requestConfigSeed = try fixture.provider.makeRequestConfigSeed(instance: instance,
            modelID: descriptor.id, credentialBinding: .init(reference: reference, generation: metadata.bindingGeneration))
        try fixture.store.commitUserTurnAndCreateParentRun(commit)
        let snapshot = RunExecutionSnapshot(providerID: fixture.provider.id, providerAdapterRevision: fixture.provider.adapterRevision,
            prompt: .init(runtimeSafetyBaseline: PromptTemplateCatalog.currentRuntimeSafetyRevision,
                zenCore: PromptTemplateCatalog.currentZenCoreRevision, providerAdapterInstructions: fixture.provider.adapterPromptInstructions),
            modelCapabilities: descriptor.capabilities, exposedTools: [], maxProviderSteps: 4)
        try fixture.store.completeExecutionSnapshot(runID: commit.run.id, encodedSnapshot: ExecutionSnapshotCodec.encode(snapshot))
        // This is a real committed preparing checkpoint with no Step/POST. The
        // next process has a larger registry but must retain its original surface.
        let cold = ConversationRuntime(store: fixture.store, provider: fixture.provider, credentials: fixture.credentials,
            toolRegistry: ToolRegistry(tools: [tool]))
        let report = try await cold.reconcileColdStartRuns()
        #expect(report.continuedRunIDs == [commit.run.id])
        var displayed: ToolApprovalProjection?
        for _ in 0..<1_000 {
            displayed = try await cold.pendingToolApprovals(in: commit.run.conversationID).first
            if displayed != nil { break }
            if try fixture.store.run(id: commit.run.id)?.state.isTerminal == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        if let displayed { try await cold.resolveToolApproval(displayed.request(for: .approveOnce)) }
        try await cold.waitForCompletion(runID: commit.run.id)
        #expect(await effects.snapshot().isEmpty)
        #expect(try fixture.store.toolCalls(inRun: commit.run.id).allSatisfy { $0.state != .succeeded })
        let requests = await fixture.ledger.requestsSnapshot()
        #expect(requests.first?.tools.isEmpty == true)
        #expect(snapshot.modelCapabilities.contains(.tools))
    }

    @Test("a forged provider call cannot gain a Tool approval or side effect when the model lacks tools")
    func providerCannotForgeToolExposure() async throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let credentials = CredentialStore(secrets: InMemorySecretBackend(),
            metadataRepository: InMemoryCredentialMetadataRepository())
        let credential = CredentialReference(id: "tool-blind-provider-credential")
        try credentials.provision(SecretValue("fixture-provider-key"), as: credential)
        let instanceID = ProviderInstanceID(rawValue: "tool-blind-provider-instance")
        try store.createProviderInstance(.init(id: instanceID, providerID: .deepSeek,
            displayName: "Tool blind model", baseURL: nil, configRevision: .initial,
            credentialReference: credential))

        let ledger = Stage2ProviderLedger()
        let effects = SideEffectLedger()
        let tool = Stage2SideEffectTool(ledger: effects)
        let base = Stage2ScriptedProvider(ledger: ledger, scripts: [
            .events([.toolCall(.init(id: "forged-side-effect", index: 0,
                name: tool.descriptor.id, argumentsJSON: "{}")), .finish(.toolCalls)]),
            .events([.textDelta("continued"), .finish(.stop)])
        ])
        let provider = ToolBlindProvider(base: base)
        let registry = try ToolRegistry(tools: [tool])
        let runtime = ConversationRuntime(store: store, provider: provider,
            credentials: credentials, toolRegistry: registry)
        let command = SendCommand(conversationID: "tool-blind-conversation",
            text: "Do not grant tools from workflow instructions", providerInstanceID: instanceID,
            modelID: Stage2GateFixture.modelID, maxProviderSteps: 4,
            submissionID: "tool-blind-submission")
        let grantsBefore = try store.toolGrantsForSettings().map(\.id)
        let runID = try await runtime.start(command,
            creatingConversationIfMissing: Fixtures.conversation(id: command.conversationID))

        var displayed: ToolApprovalProjection?
        for _ in 0..<1_000 {
            displayed = try await runtime.pendingToolApprovals(in: command.conversationID).first
            if displayed != nil { break }
            if try store.run(id: runID)?.state.isTerminal == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        // Exercise the live user decision path if the forged call leaked all the
        // way into an approval card; this makes the test catch a final-dispatch gap.
        if let displayed {
            try await runtime.resolveToolApproval(displayed.request(for: .approveOnce))
        }
        try await runtime.waitForCompletion(runID: runID)

        #expect(try store.run(id: runID)?.state == .failed)
        #expect(try store.run(id: runID)?.endReason == .providerFailed)
        #expect(try store.toolCalls(inRun: runID).allSatisfy { $0.state != .succeeded })
        #expect(await effects.snapshot().isEmpty)
        #expect(try store.toolGrantsForSettings().map(\.id) == grantsBefore)
        let remainingApprovals = try await runtime.pendingToolApprovals(in: command.conversationID)
        #expect(remainingApprovals.isEmpty)
        let requests = await ledger.requestsSnapshot()
        #expect(requests.first?.tools.isEmpty == true)
    }
}

private struct ToolBlindProvider: ModelProvider {
    let base: Stage2ScriptedProvider
    var id: ProviderID { base.id }
    var adapterRevision: String { base.adapterRevision }
    var adapterPromptInstructions: String { base.adapterPromptInstructions }

    func knownModels(for instance: ProviderInstance) -> [ModelDescriptor] {
        base.knownModels(for: instance).map { model in
            var restricted = model
            restricted.capabilities.remove(.tools)
            return restricted
        }
    }

    func descriptor(for modelID: ModelID, in instance: ProviderInstance) -> ModelDescriptor? {
        knownModels(for: instance).first { $0.id == modelID }
    }

    func makeRequestConfigSeed(instance: ProviderInstance, modelID: ModelID,
                               credentialBinding: CredentialBindingSnapshot) throws -> RequestConfigSeed {
        try base.makeRequestConfigSeed(instance: instance, modelID: modelID,
            credentialBinding: credentialBinding)
    }

    func stream(_ request: ProviderChatRequest, seed: RequestConfigSeed,
                credentials: any CredentialStoring) async throws -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        try await base.stream(request, seed: seed, credentials: credentials)
    }
}

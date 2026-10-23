import Foundation
import Testing

@testable import ZenAgent

@Suite("Tool exposure respects model capability")
struct ToolExposureCapabilityTests {
    @Test(arguments: [true, false])
    func originalSnapshotAndActualRequestExposeOnlySupportedTools(supportsTools: Bool) async throws {
        let f = try I05RuntimeTestFixtures.makeFixture()
        var capabilities: Set<ModelCapability> = [.text, .streaming]
        if supportsTools { capabilities.insert(.tools) }
        let ledger = ToolExposureRequestLedger()
        let provider = ToolExposureRecordingProvider(base: FakeProvider(instanceID: f.instance.id,
            capabilities: capabilities, scriptedEvents: [.textDelta("text response"), .finish(.stop)]), ledger: ledger)
        let registry = try ToolRegistry(tools: [CalculatorTool()])
        let runtime = ConversationRuntime(store: f.store, provider: provider, credentials: f.credentials, toolRegistry: registry)
        let runID = try await runtime.send(I05RuntimeTestFixtures.command())
        let run = try #require(try f.store.run(id: runID))
        #expect(run.state == .completed)
        let snapshot = try ExecutionSnapshotCodec.decode(try #require(run.executionSnapshot))
        let expected = supportsTools ? ["calculator"] : []
        #expect(snapshot.exposedTools.map(\.toolID) == expected)
        let requests = await ledger.snapshot()
        #expect(requests.count == 1)
        #expect(requests.first?.tools.map(\.name) == expected)
    }
}

private actor ToolExposureRequestLedger {
    private var requests: [ProviderChatRequest] = []
    func record(_ request: ProviderChatRequest) { requests.append(request) }
    func snapshot() -> [ProviderChatRequest] { requests }
}

private struct ToolExposureRecordingProvider: ModelProvider {
    let base: FakeProvider
    let ledger: ToolExposureRequestLedger
    var id: ProviderID { base.id }
    var adapterRevision: String { base.adapterRevision }
    var adapterPromptInstructions: String { base.adapterPromptInstructions }
    func knownModels(for instance: ProviderInstance) -> [ModelDescriptor] { base.knownModels(for: instance) }
    func descriptor(for modelID: ModelID, in instance: ProviderInstance) -> ModelDescriptor? { base.descriptor(for: modelID, in: instance) }
    func makeRequestConfigSeed(instance: ProviderInstance, modelID: ModelID, credentialBinding: CredentialBindingSnapshot) throws -> RequestConfigSeed {
        try base.makeRequestConfigSeed(instance: instance, modelID: modelID, credentialBinding: credentialBinding)
    }
    func stream(_ request: ProviderChatRequest, seed: RequestConfigSeed, credentials: any CredentialStoring) async throws -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        await ledger.record(request)
        return try await base.stream(request, seed: seed, credentials: credentials)
    }
}

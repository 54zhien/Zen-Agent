import Foundation
import Testing

@testable import ZenAgent

@Suite("Composer runtime action bridge")
struct ComposerRuntimeActionBridgeTests {
    @Test("bridgeStartReturnsAtAcceptanceAndPublishesProjection")
    func bridgeStartReturnsAtAcceptanceAndPublishesProjection() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let box = I05BlockingStreamBox()
        let provider = I05BlockingProvider(box: box, instanceID: fixture.instance.id)
        let runtime = ConversationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials
        )
        let bridge = ComposerRuntimeActionBridge(runtime: runtime)
        let updates = await bridge.projectionUpdates(I05RuntimeTestFixtures.conversationID)
        var iterator = updates.makeAsyncIterator()
        _ = await iterator.next()

        let runID = try await bridge.start(
            I05RuntimeTestFixtures.command()
        )
        await box.waitUntilReady()
        let activeProjection = try await bridge.projection(
            I05RuntimeTestFixtures.conversationID
        )
        #expect(activeProjection?.runID == runID)
        #expect(activeProjection?.isActive == true)
        #expect(await runtime.activeOperationCount == 1)

        var receivedMatchingProjection = false
        while let value = await iterator.next() {
            if let projection = value,
               projection.runID == runID,
               projection.isActive {
                receivedMatchingProjection = true
                break
            }
        }
        #expect(receivedMatchingProjection)

        try await bridge.stop(runID)
        try await runtime.waitForCompletion(runID: runID)
        #expect(await runtime.activeOperationCount == 0)
    }

    @Test("modelOptionsComeFromSelectedProviderInstance")
    func modelOptionsComeFromSelectedProviderInstance() async throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let credentials = CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: InMemoryCredentialMetadataRepository()
        )
        let first = ProviderInstance(
            id: ProviderInstanceID(rawValue: "catalog-instance-one"),
            providerID: .deepSeek,
            displayName: "First",
            baseURL: nil,
            configRevision: .initial,
            credentialReference: nil
        )
        let second = ProviderInstance(
            id: ProviderInstanceID(rawValue: "catalog-instance-two"),
            providerID: .deepSeek,
            displayName: "Second",
            baseURL: nil,
            configRevision: .initial,
            credentialReference: nil
        )
        try store.createProviderInstance(first)
        try store.createProviderInstance(second)

        let runtime = ConversationRuntime(
            store: store,
            provider: BridgeCatalogProvider(),
            credentials: credentials
        )
        let bridge = ComposerRuntimeActionBridge(runtime: runtime)
        let firstModels = try await bridge.models(first.id)
        let secondModels = try await bridge.models(second.id)

        #expect(firstModels.map(\.id) == [ModelID(rawValue: "model-catalog-instance-one")])
        #expect(secondModels.map(\.id) == [ModelID(rawValue: "model-catalog-instance-two")])
        #expect(firstModels.allSatisfy { $0.providerInstanceID == first.id })
        #expect(secondModels.allSatisfy { $0.providerInstanceID == second.id })
    }
}

private struct BridgeCatalogProvider: ModelProvider {
    var id: ProviderID { .deepSeek }
    var adapterRevision: String { "bridge-catalog-provider.v1" }
    var adapterPromptInstructions: String { "" }

    func knownModels(for instance: ProviderInstance) -> [ModelDescriptor] {
        [ModelDescriptor(
            id: ModelID(rawValue: "model-\(instance.id.rawValue)"),
            providerInstanceID: instance.id,
            displayName: instance.displayName,
            capabilities: [.text, .streaming]
        )]
    }

    func descriptor(for modelID: ModelID, in instance: ProviderInstance) -> ModelDescriptor? {
        knownModels(for: instance).first { $0.id == modelID }
    }

    func makeRequestConfigSeed(
        instance: ProviderInstance,
        modelID: ModelID,
        credentialBinding: CredentialBindingSnapshot
    ) throws -> RequestConfigSeed {
        RequestConfigSeed(
            instance: instance,
            modelID: modelID,
            credentialBinding: credentialBinding,
            resolvedEndpoint: URL(string: "https://bridge-catalog.invalid/chat")!
        )
    }

    func stream(
        _ request: ProviderChatRequest,
        seed: RequestConfigSeed,
        credentials: any CredentialStoring
    ) async throws -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

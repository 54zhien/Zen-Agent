import Foundation
import Testing
@testable import ZenAgent

@Suite("Image input model settings")
@MainActor
struct ImageInputModelSettingsTests {
    @Test("image model selection persists independently and clears without changing the main model")
    func imageModelSelectionIsIndependentAndPersistent() async throws {
        let environment = try makeEnvironment()
        defer { environment.defaults.removePersistentDomain(forName: environment.suite) }
        let mainTarget = AppExecutionTarget(
            providerInstanceID: ProviderInstanceID(rawValue: "main-account"),
            modelID: ModelID(rawValue: "main-model")
        )
        environment.defaults.set(mainTarget.providerInstanceID.rawValue, forKey: AppShellModel.defaultInstanceIDKey)
        environment.defaults.set(mainTarget.modelID.rawValue, forKey: AppShellModel.defaultModelIDKey)

        let settings = makeSettings(environment, capabilities: [.text, .streaming, .vision])
        await settings.load()

        #expect(await settings.setImageInputModel(
            providerInstanceID: environment.instance.id,
            modelID: environment.modelID
        ))

        let restored = makeSettings(environment, capabilities: [.text, .streaming, .vision])
        await restored.load()
        #expect(restored.imageInputTarget == AppExecutionTarget(
            providerInstanceID: environment.instance.id,
            modelID: environment.modelID
        ))
        #expect(restored.defaultTarget == mainTarget)
        #expect(environment.defaults.string(forKey: AppShellModel.defaultInstanceIDKey) == "main-account")
        #expect(environment.defaults.string(forKey: AppShellModel.defaultModelIDKey) == "main-model")
        #expect(restored.imageInputAccountName == "Vision account")
        #expect(restored.imageInputProviderName == "image-settings-provider")
        #expect(restored.imageInputEndpointDisplay == "https://images.example.test:8443/v1/responses")
        #expect(restored.imageInputAvailabilityMessage.contains("尚未接入发送流程"))

        restored.clearImageInputModel()
        #expect(restored.imageInputTarget == nil)
        #expect(environment.defaults.string(forKey: AppShellModel.imageInputInstanceIDKey) == nil)
        #expect(environment.defaults.string(forKey: AppShellModel.imageInputModelIDKey) == nil)
        #expect(environment.defaults.string(forKey: AppShellModel.defaultInstanceIDKey) == "main-account")
        #expect(environment.defaults.string(forKey: AppShellModel.defaultModelIDKey) == "main-model")
    }

    @Test("a saved selection becomes unavailable when its model no longer declares vision")
    func staleImageModelRemainsVisibleAsUnavailable() async throws {
        let environment = try makeEnvironment()
        defer { environment.defaults.removePersistentDomain(forName: environment.suite) }
        let initial = makeSettings(environment, capabilities: [.text, .streaming, .vision])
        await initial.load()
        #expect(await initial.setImageInputModel(
            providerInstanceID: environment.instance.id,
            modelID: environment.modelID
        ))

        let updated = makeSettings(environment, capabilities: [.text, .streaming])
        await updated.load()

        #expect(updated.imageInputTarget == AppExecutionTarget(
            providerInstanceID: environment.instance.id,
            modelID: environment.modelID
        ))
        #expect(updated.imageInputAvailabilityMessage.contains("不再支持图像输入"))
        #expect(updated.imageInputAccountName == "Vision account")
        #expect(updated.imageInputEndpointDisplay == "https://images.example.test:8443/v1/responses")
        let rejected = await updated.setImageInputModel(
            providerInstanceID: environment.instance.id,
            modelID: environment.modelID
        )
        #expect(!rejected)

        updated.clearImageInputModel()
        #expect(updated.imageInputTarget == nil)
    }

    @Test("a catalog read failure is not reported as an empty image model catalog")
    func catalogFailureIsDistinctFromNoImageModels() async throws {
        let failedEnvironment = try makeEnvironment()
        defer { failedEnvironment.defaults.removePersistentDomain(forName: failedEnvironment.suite) }
        try failedEnvironment.store.database.write { db in
            try db.execute(sql: "UPDATE providerInstance SET baseURL = ? WHERE id = ?",
                arguments: ["not a URL", failedEnvironment.instance.id.rawValue])
        }
        let failedSettings = makeSettings(failedEnvironment, capabilities: [.text, .streaming])
        await failedSettings.load()
        #expect(failedSettings.imageInputCatalogStatusMessage?.contains("读取失败") == true)
        #expect(failedSettings.imageInputCatalogStatusMessage?.contains("没有模型声明") == false)

        let emptyEnvironment = try makeEnvironment()
        defer { emptyEnvironment.defaults.removePersistentDomain(forName: emptyEnvironment.suite) }
        let emptySettings = makeSettings(emptyEnvironment, capabilities: [.text, .streaming])
        await emptySettings.load()
        #expect(emptySettings.imageInputCatalogStatusMessage == nil)
        #expect(emptySettings.catalog.flatMap { emptySettings.imageInputModels(in: $0) }.isEmpty)
    }

    private struct Environment {
        let suite: String
        let defaults: UserDefaults
        let store: PersistenceStore
        let credentials: CredentialStore
        let instance: ProviderInstance
        let modelID: ModelID
    }

    private func makeEnvironment() throws -> Environment {
        let suite = "ZenAgentTests.ImageInputSettings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let credentials = CredentialStore(secrets: InMemorySecretBackend(), metadataRepository: store)
        let reference = CredentialReference(id: "image-settings-fixture-reference")
        try credentials.provision(SecretValue("image-settings-fixture-secret"), as: reference,
            principalFingerprint: nil, at: Fixtures.epoch)
        let instance = ProviderInstance(id: ProviderInstanceID(rawValue: "image-settings-account"),
            providerID: ProviderID(rawValue: "image-settings-provider"), displayName: "Vision account",
            baseURL: nil, configRevision: .initial, credentialReference: reference)
        try store.createProviderInstance(instance)
        return Environment(suite: suite, defaults: defaults, store: store, credentials: credentials,
            instance: instance, modelID: ModelID(rawValue: "vision-model"))
    }

    private func makeSettings(_ environment: Environment, capabilities: Set<ModelCapability>) -> SettingsWorkspaceModel {
        let provider = ImageSettingsProvider(modelID: environment.modelID, capabilities: capabilities)
        let providerRegistry = ModelProviderRegistry(provider: provider)
        let mcpRegistry = MCPServerRegistry(store: environment.store)
        let mcpRuntime = MCPServerRuntime(registry: mcpRegistry, store: environment.store,
            credentials: environment.credentials, transport: FakeHTTPTransport())
        return SettingsWorkspaceModel(store: environment.store, credentials: environment.credentials,
            provider: provider, defaults: environment.defaults,
            appearance: AppearanceSettings(defaults: environment.defaults),
            menus: ModelMenuPreferences(defaults: environment.defaults), files: nil,
            mcpRegistry: mcpRegistry, mcpRuntime: mcpRuntime, providerRegistry: providerRegistry,
            onDefault: { _, _ in })
    }
}

private struct ImageSettingsProvider: ModelProvider {
    let id = ProviderID(rawValue: "image-settings-provider")
    let modelID: ModelID
    let capabilities: Set<ModelCapability>

    var adapterRevision: String { "image-settings-fixture.v1" }
    var adapterPromptInstructions: String { "Fixture provider for image settings." }

    func knownModels(for instance: ProviderInstance) -> [ModelDescriptor] {
        [ModelDescriptor(id: modelID, providerInstanceID: instance.id, displayName: "Vision model",
            capabilities: capabilities)]
    }

    func descriptor(for modelID: ModelID, in instance: ProviderInstance) -> ModelDescriptor? {
        knownModels(for: instance).first { $0.id == modelID }
    }

    func makeRequestConfigSeed(instance: ProviderInstance, modelID: ModelID,
                               credentialBinding: CredentialBindingSnapshot) throws -> RequestConfigSeed {
        guard descriptor(for: modelID, in: instance) != nil else {
            throw ProviderError.invalidRequest("unknown fixture model")
        }
        return RequestConfigSeed(instance: instance, modelID: modelID, credentialBinding: credentialBinding,
            resolvedEndpoint: URL(string: "https://user:password@images.example.test:8443/v1/responses?token=fixture#fragment")!)
    }

    func stream(_ request: ProviderChatRequest, seed: RequestConfigSeed,
                credentials: any CredentialStoring) async throws -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

import Foundation
import Testing

@testable import ZenAgent

@Suite("GLM provider setup")
@MainActor
struct GLMProviderSetupTests {
    @Test("GLM model is selectable and its account saves through shared provider setup")
    func setupSavesGLMAccount() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let credentials = CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: InMemoryCredentialMetadataRepository()
        )
        let transport = FakeHTTPTransport()
        let registry = try ModelProviderRegistry(providers: [
            DeepSeekProvider(transport: transport),
            OpenAIProvider(transport: transport),
            GLMProvider(transport: transport),
        ])
        let suite = "ZenAgentTests.GLMProviderSetup.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let setup = ProviderSetupModel(
            store: store,
            credentials: credentials,
            providerRegistry: registry,
            userDefaults: defaults
        )

        #expect(setup.providers.contains(.glm))
        setup.selectedProviderID = .glm
        #expect(setup.selectedModelID == GLMProvider.defaultModelID)
        setup.apiKey = "glm-setup-test-key"

        #expect(setup.save())
        let instance = try #require(try store.providerInstance(id: setup.instanceID))
        #expect(instance.providerID == .glm)
        #expect(instance.displayName == "GLM")
        #expect(instance.credentialReference == setup.credentialReference)
        #expect(defaults.string(forKey: AppShellModel.defaultModelIDKey) == "glm-5.3")
    }
}
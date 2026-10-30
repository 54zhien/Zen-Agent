import Foundation
import Testing

@testable import ZenAgent

@Suite("Subagent Settings")
@MainActor
struct SubagentSettingsTests {
    @Test("model selection validates and persists the selected executable target")
    func explicitSelectionUsesTheProviderAndCredentialBinding() async throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let instanceID = ProviderInstanceID(rawValue: "subagent-settings-provider")
        let reference = CredentialReference(id: "subagent-settings-credential", kind: .apiKey)
        let instance = ProviderInstance(
            id: instanceID,
            providerID: .deepSeek,
            displayName: "Settings provider",
            baseURL: nil,
            configRevision: .initial,
            credentialReference: reference
        )
        try store.createProviderInstance(instance)

        let credentials = CredentialStore(secrets: InMemorySecretBackend(), metadataRepository: store)
        try credentials.provision(
            SecretValue("subagent-settings-fixture-secret"),
            as: reference,
            principalFingerprint: nil,
            at: Fixtures.epoch
        )
        let provider = FakeProvider(
            id: .deepSeek,
            instanceID: instanceID,
            modelNames: ["child-model"],
            capabilities: [.text, .streaming, .reasoning]
        )
        let executableModel = try #require(provider.knownModels(for: instance).first)
        let model = SubagentSettingsModel(store: store, provider: provider, credentials: credentials)
        model.updateProviderCatalog([
            SettingsProviderCatalog(
                instance: instance,
                models: [
                    executableModel,
                    ModelDescriptor(
                        id: ModelID(rawValue: "text-only"),
                        providerInstanceID: instanceID,
                        displayName: "Text only",
                        capabilities: [.text]
                    )
                ],
                credentialStatus: "active fixture",
                credentialIsActive: true
            )
        ])
        await model.load()

        #expect(model.modelOptions.map(\.target) == [DelegationModelTarget(
            providerInstanceID: instanceID,
            modelID: executableModel.id
        )])
        await model.setExplicitModelTarget(DelegationModelTarget(
            providerInstanceID: instanceID,
            modelID: executableModel.id
        ))

        let saved = try store.delegationConfiguration()
        #expect(saved.enabled == false)
        #expect(saved.explicitModelTarget == DelegationModelTarget(
            providerInstanceID: instanceID,
            modelID: executableModel.id
        ))
        #expect(saved.revision == 1)
        #expect(model.errorMessage == nil)
    }

    @Test("an unavailable saved target remains visible and can be disabled without replacement")
    func unavailableTargetIsPreservedWhileTogglingEnabled() async throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let staleTarget = DelegationModelTarget(
            providerInstanceID: ProviderInstanceID(rawValue: "removed-provider"),
            modelID: ModelID(rawValue: "removed-model")
        )
        _ = try store.setDelegationConfiguration(enabled: true, explicitModelTarget: staleTarget)

        let model = SubagentSettingsModel(
            store: store,
            provider: FakeProvider(),
            credentials: CredentialStore(secrets: InMemorySecretBackend(), metadataRepository: store)
        )
        model.updateProviderCatalog([])
        await model.load()

        #expect(model.modelSelection == .unavailable)
        await model.setEnabled(false)
        #expect(model.modelSelection == .unavailable)
        #expect(model.configuration?.enabled == false)
        #expect(model.configuration?.explicitModelTarget == staleTarget)

        await model.setEnabled(true)
        #expect(model.configuration?.enabled == true)
        #expect(model.configuration?.explicitModelTarget == staleTarget)
        #expect(model.errorMessage == nil)
    }
}

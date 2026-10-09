import Foundation
import Testing
@testable import ZenAgent

@Suite("Settings account ownership")
@MainActor
struct SettingsAccountTests {
    @Test("successful reauthentication preserves historical credentials and unsaved configuration")
    func reauthenticationDoesNotSaveOtherDraftsOrLogoutOldReferences() async throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let backend = InMemorySecretBackend()
        let credentials = CredentialStore(secrets: backend, metadataRepository: store)
        let old = CredentialReference(id: "settings-success-old-reference")
        let fresh = CredentialReference(id: "settings-success-fresh-reference")
        try credentials.provision(SecretValue("old-success-fixture"), as: old,
            principalFingerprint: nil, at: Fixtures.epoch)
        let instance = ProviderInstance(id: .init(rawValue: "settings-success-account"),
            providerID: .deepSeek, displayName: "Persisted name", baseURL: nil,
            configRevision: .initial, credentialReference: old)
        try store.createProviderInstance(instance)
        let editor = ProviderAccountSettingsModel(store: store, credentials: credentials, instance: instance,
            makeCredentialReference: { fresh })
        editor.displayName = "unsaved name"
        editor.endpoint = "https://unsaved.example.com"
        editor.apiKey = "fresh-success-fixture"
        await editor.reauthenticate()
        let accepted = try #require(try store.providerInstance(id: instance.id))
        #expect(accepted.credentialReference == fresh)
        #expect(accepted.displayName == instance.displayName && accepted.baseURL == nil)
        #expect(accepted.configRevision == instance.configRevision)
        #expect(try credentials.resolve(frozenReference: old, generation: 1)?.revealed == "old-success-fixture")
        #expect(try credentials.resolve(fresh)?.revealed == "fresh-success-fixture")
        #expect(editor.displayName == "unsaved name" && editor.endpoint == "https://unsaved.example.com")
        #expect(editor.apiKey.isEmpty && editor.errorMessage == nil)
    }

    @Test("stale reauthentication cannot replace the accepted credential or discard local input")
    func staleReauthenticationPreservesBothOwners() async throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let backend = InMemorySecretBackend()
        let credentials = CredentialStore(secrets: backend, metadataRepository: store)
        let reference = CredentialReference(id: "settings-old-reference", kind: .apiKey)
        try credentials.provision(SecretValue("old-fixture-secret"), as: reference,
            principalFingerprint: nil, at: Fixtures.epoch)
        let instance = ProviderInstance(id: .init(rawValue: "settings-account"),
            providerID: .deepSeek, displayName: "Original", baseURL: nil,
            configRevision: .initial, credentialReference: reference)
        try store.createProviderInstance(instance)
        let fresh = CredentialReference(id: "settings-owned-rejected-reference", kind: .apiKey)
        let editor = ProviderAccountSettingsModel(store: store, credentials: credentials, instance: instance,
            makeCredentialReference: { fresh })
        editor.displayName = "unsaved local name"
        editor.endpoint = "https://local.example.com"
        editor.apiKey = "new-fixture-secret"
        _ = try store.reconfigureProviderInstance(id: instance.id, displayName: "Accepted elsewhere",
            baseURL: URL(string: "https://accepted.example.com"), expectedEditRevision: instance.editRevision)

        await editor.reauthenticate()

        let accepted = try #require(try store.providerInstance(id: instance.id))
        #expect(accepted.displayName == "Accepted elsewhere")
        #expect(accepted.credentialReference == reference)
        #expect(try credentials.resolve(reference)?.revealed == "old-fixture-secret")
        #expect(editor.displayName == "unsaved local name")
        #expect(editor.endpoint == "https://local.example.com")
        #expect(editor.apiKey == "new-fixture-secret")
        #expect(editor.errorMessage != nil && editor.errorMessage?.contains(editor.apiKey) == false)
        #expect(try backend.load(fresh, generation: 1) == nil,
                "A confirmed unpublished attachment must release only its newly owned secret")
    }

    @Test("a generated reference collision cannot acquire ownership of an existing secret")
    func referenceCollisionKeepsTheExistingSecret() async throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let backend = InMemorySecretBackend()
        let credentials = CredentialStore(secrets: backend, metadataRepository: store)
        let reference = CredentialReference(id: "settings-collision-reference", kind: .apiKey)
        try credentials.provision(SecretValue("retained-collision-fixture"), as: reference,
            principalFingerprint: nil, at: Fixtures.epoch)
        let instance = ProviderInstance(id: .init(rawValue: "settings-collision-account"),
            providerID: .deepSeek, displayName: "Retained", baseURL: nil,
            configRevision: .initial, credentialReference: reference)
        try store.createProviderInstance(instance)
        let editor = ProviderAccountSettingsModel(store: store, credentials: credentials, instance: instance,
            makeCredentialReference: { reference })
        editor.apiKey = "rejected-collision-fixture"
        await editor.reauthenticate()
        #expect(try credentials.resolve(reference)?.revealed == "retained-collision-fixture")
        #expect(try store.providerInstance(id: instance.id) == instance)
        #expect(editor.apiKey == "rejected-collision-fixture" && editor.errorMessage != nil)
    }

    @Test("unsafe endpoints are rejected before a configuration mutation")
    func unsafeEndpointsNeverReplaceThePersistedEndpoint() async throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let credentials = CredentialStore(secrets: InMemorySecretBackend(), metadataRepository: store)
        let instance = ProviderInstance(id: .init(rawValue: "endpoint-account"), providerID: .deepSeek,
            displayName: "Original", baseURL: URL(string: "https://original.example.com"),
            configRevision: .initial)
        try store.createProviderInstance(instance)
        for endpoint in ["http://plain.example.com", "file:///tmp/private", "javascript:alert(1)",
                         "https://user:password@example.com", "https://"] {
            let editor = ProviderAccountSettingsModel(store: store, credentials: credentials, instance: instance)
            editor.endpoint = endpoint
            await editor.saveConfiguration()
            #expect(try store.providerInstance(id: instance.id) == instance)
            #expect(editor.endpoint == endpoint && editor.errorMessage != nil)
        }
    }
}

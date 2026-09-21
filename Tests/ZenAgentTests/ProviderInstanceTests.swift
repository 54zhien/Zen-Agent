import Foundation
import GRDB
import Testing

@testable import ZenAgent

/// Product invariant: **a run's frozen configuration does not move when the instance it
/// names is later edited.**
///
/// The instance id is not enough to answer this. An instance keeps its id while its
/// endpoint, provider type and display name change underneath, so a run that recorded
/// only the id would believe it still matched a configuration it was never frozen
/// against — and would resume against whatever the endpoint had become.
@Suite("Provider instance")
struct ProviderInstanceTests {

    private static let instanceID = ProviderInstanceID(rawValue: "pi-1")
    private static let reference = CredentialReference(id: "cred-1")

    private func makeStore() throws -> PersistenceStore {
        PersistenceStore(database: try ZenDatabase.inMemory())
    }

    private func seedInstance(_ store: PersistenceStore) throws -> ProviderInstance {
        let instance = ProviderInstance(
            id: Self.instanceID,
            providerID: .deepSeek,
            displayName: "DeepSeek",
            baseURL: URL(string: "https://api.deepseek.com"),
            configRevision: .initial,
            credentialReference: CredentialReference(id: "cred-1")
        )
        try store.createProviderInstance(instance)
        return instance
    }

    // MARK: - Identity

    @Test("an instance round-trips with its identity intact")
    func identityRoundTrips() throws {
        let store = try makeStore()
        let saved = try seedInstance(store)

        let loaded = try store.providerInstance(id: Self.instanceID)
        #expect(loaded == saved, "an unchanged instance must come back byte for byte")
        #expect(loaded?.providerID == .deepSeek, "the provider family and the instance are separate identities")
    }

    @Test("an unknown instance resolves to nil rather than a default")
    func unknownInstanceIsNil() throws {
        let store = try makeStore()
        #expect(try store.providerInstance(id: ProviderInstanceID(rawValue: "nope")) == nil)
    }

    @Test("an unknown stored credential kind is rejected rather than rewritten as apiKey")
    func corruptedCredentialKindIsRejected() throws {
        let store = try makeStore()
        try seedInstance(store)

        try store.database.write { db in
            try db.execute(
                sql: "UPDATE providerInstance SET credentialKind = ? WHERE id = ?",
                arguments: [
                    "oauth-that-this-build-does-not-know",
                    Self.instanceID.rawValue,
                ]
            )
        }

        var failure: Error?
        do {
            _ = try store.providerInstance(id: Self.instanceID)
        } catch {
            failure = error
        }

        #expect(
            failure != nil,
            "corrupted credential metadata must not silently become .apiKey"
        )
    }

    @Test("half of a stored credential reference is rejected rather than completed by default")
    func incompleteCredentialReferenceIsRejected() throws {
        let store = try makeStore()
        try seedInstance(store)

        try store.database.write { db in
            try db.execute(
                sql: """
                    UPDATE providerInstance
                    SET credentialKind = NULL
                    WHERE id = ?
                    """,
                arguments: [Self.instanceID.rawValue]
            )
        }

        var failure: Error?
        do {
            _ = try store.providerInstance(id: Self.instanceID)
        } catch {
            failure = error
        }

        #expect(
            failure != nil,
            "credentialID without credentialKind must not be rewritten as apiKey"
        )
    }

    @Test("a stored provider base URL must remain an absolute URL")
    func corruptedBaseURLIsRejected() throws {
        let store = try makeStore()
        try seedInstance(store)

        try store.database.write { db in
            try db.execute(
                sql: """
                    UPDATE providerInstance
                    SET baseURL = ?
                    WHERE id = ?
                    """,
                arguments: [
                    "not-an-absolute-url",
                    Self.instanceID.rawValue,
                ]
            )
        }

        var failure: Error?
        do {
            _ = try store.providerInstance(id: Self.instanceID)
        } catch {
            failure = error
        }

        #expect(
            failure != nil,
            "damaged stored configuration must not be returned as usable"
        )
    }

    // MARK: - Config revision

    @Test("editing an instance bumps the revision and only the revision")
    func editingBumpsTheRevision() throws {
        let store = try makeStore()
        let original = try seedInstance(store)

        let edited = try store.reconfigureProviderInstance(
            id: Self.instanceID,
            displayName: "DeepSeek (work)",
            baseURL: URL(string: "https://proxy.example.com"),
            expectedEditRevision: original.editRevision
        )

        #expect(edited.configRevision != original.configRevision, "an edit must move the revision")
        #expect(edited.displayName == "DeepSeek (work)")
        #expect(edited.baseURL?.absoluteString == "https://proxy.example.com")
    }

    @Test("editing does not disturb the credential reference")
    func editingKeepsTheCredential() throws {
        let store = try makeStore()
        let original = try seedInstance(store)

        let edited = try store.reconfigureProviderInstance(
            id: Self.instanceID,
            displayName: "renamed",
            baseURL: nil,
            expectedEditRevision: original.editRevision
        )

        // Attaching or detaching a credential is a separate act. Folding it into a
        // rename would mean an edit could silently drop one.
        #expect(edited.credentialReference == CredentialReference(id: "cred-1"))
    }

    @Test("configuring an unknown instance is refused")
    func configuringUnknownInstanceFails() throws {
        let store = try makeStore()

        var failure: Error?
        do {
            _ = try store.reconfigureProviderInstance(
                id: ProviderInstanceID(rawValue: "nope"),
                displayName: "x",
                baseURL: nil,
                expectedEditRevision: .initial
            )
        } catch {
            failure = error
        }

        #expect(
            failure as? PersistenceError == .providerInstanceNotFound(ProviderInstanceID(rawValue: "nope"))
        )
    }

    // MARK: - Frozen seed

    @Test("a frozen seed stops matching once the instance is edited")
    func frozenSeedDoesNotDrift() throws {
        let store = try makeStore()
        let instance = try seedInstance(store)

        // What Send freezes.
        let seed = RequestConfigSeed(
            instance: instance,
            modelID: ModelID(rawValue: "deepseek-chat"),
            credentialBinding: CredentialBindingSnapshot(reference: Self.reference, generation: 1),
            resolvedEndpoint: DeepSeekProvider.resolvedEndpoint(for: instance)
        )
        #expect(instance.matches(seed), "the seed must match the instance it was frozen from")

        let edited = try store.reconfigureProviderInstance(
            id: Self.instanceID,
            displayName: "DeepSeek",
            baseURL: URL(string: "https://somewhere-else.example.com"),
            expectedEditRevision: instance.editRevision
        )

        #expect(
            !edited.matches(seed),
            """
            a run frozen before the edit must not match the edited instance. The id is \
            unchanged, so only the revision can tell — and a run that resumed here would \
            be talking to an endpoint it was never pointed at.
            """
        )
        #expect(edited.matches(RequestConfigSeed(
            instance: edited,
            modelID: ModelID(rawValue: "deepseek-chat"),
            credentialBinding: CredentialBindingSnapshot(reference: Self.reference, generation: 1),
            resolvedEndpoint: DeepSeekProvider.resolvedEndpoint(for: edited)
        )))
    }

    @Test("the frozen seed survives the instance being edited, in storage")
    func theRunKeepsItsOwnSeed() throws {
        let store = try makeStore()
        let instance = try seedInstance(store)
        try store.commitUserTurnAndCreateParentRun(Fixtures.send(messageID: "m1", runID: "r1"))

        let seedBefore: RequestConfigSeed? = try store.run(id: "r1").map(\.requestConfigSeed)

        _ = try store.reconfigureProviderInstance(
            id: Self.instanceID,
            displayName: "changed",
            baseURL: URL(string: "https://elsewhere.example.com"),
            expectedEditRevision: instance.editRevision
        )

        // The instance moved; the run did not. This is the whole point of freezing.
        #expect(
            try store.run(id: "r1")?.requestConfigSeed == seedBefore,
            "editing an instance must not reach back into a run that already started"
        )
        guard let seedBefore else {
            Issue.record("expected a frozen seed on the run")
            return
        }
        #expect(
            try store.providerInstance(id: Self.instanceID)?.matches(seedBefore) == false,
            "and the instance the run names must now report that it no longer matches"
        )
    }

    // MARK: - Credential binding

    @Test("the credential binding generation belongs to the credential, not the instance")
    func bindingGenerationLivesWithTheCredential() throws {
        let store = try makeStore()
        try seedInstance(store)

        let credentials = CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: store
        )
        let reference = Self.reference
        try credentials.provision(SecretValue("sk-1"), as: reference, principalFingerprint: "acct-a")

        guard let instance = try store.providerInstance(id: Self.instanceID),
              let generation = try credentials.metadata(for: reference)?.bindingGeneration else {
            Issue.record("expected the instance and its credential metadata to exist")
            return
        }
        let seed = RequestConfigSeed(
            instance: instance,
            modelID: ModelID(rawValue: "deepseek-chat"),
            credentialBinding: CredentialBindingSnapshot(reference: reference, generation: generation),
            resolvedEndpoint: DeepSeekProvider.resolvedEndpoint(for: instance)
        )
        #expect(seed.credentialBinding.generation == 1)

        // Rebinding the credential moves the generation, and the seed stops matching —
        // without anything about the instance changing.
        try credentials.rebind(SecretValue("sk-2"), as: reference, principalFingerprint: "acct-b")
        #expect(
            try !credentials.matchesBinding(reference, generation: seed.credentialBinding.generation),
            """
            the reference id is identical before and after a rebind, so only the \
            generation can tell a suspended run that its credential now belongs to \
            somebody else
            """
        )
    }

    // MARK: - Removing a credential keeps the instance

    @Test("removing the credential leaves the instance as an unauthenticated one")
    func removingCredentialKeepsTheInstance() throws {
        let store = try makeStore()
        try seedInstance(store)

        let credentials = CredentialStore(secrets: InMemorySecretBackend(), metadataRepository: store)
        try credentials.provision(SecretValue("sk-1"), as: CredentialReference(id: "cred-1"))
        try credentials.logout(CredentialReference(id: "cred-1"))

        let after = try store.providerInstance(id: Self.instanceID)
        #expect(
            after != nil,
            "the user's configuration outlives the secret. Deleting the credential must not delete the endpoint they typed in"
        )
        #expect(after?.credentialReference != nil, "the reference stays; only the material is gone")
        #expect(after?.displayName == "DeepSeek")
    }

    @Test("deleting the instance does not delete the credential")
    func deletingTheInstanceLeavesTheCredential() throws {
        let store = try makeStore()
        try seedInstance(store)

        let credentials = CredentialStore(secrets: InMemorySecretBackend(), metadataRepository: store)
        let reference = CredentialReference(id: "cred-1")
        try credentials.provision(SecretValue("sk-1"), as: reference)

        try store.deleteProviderInstance(id: Self.instanceID)

        // The other direction of the same care: a credential another instance may share
        // must not be removed as a side effect of deleting one config.
        #expect(try store.providerInstance(id: Self.instanceID) == nil)
        #expect(
            try credentials.metadata(for: reference) != nil,
            "deleting a configuration must not destroy a credential it was merely pointing at"
        )
    }
}

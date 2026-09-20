import Foundation
import Testing

@testable import ZenAgent

/// Product invariant: **"not signed in", "can't read the keychain right now" and "the
/// credential was rejected" are three different situations.**
///
/// They are easy to collapse into one "login failed", and collapsing them is expensive:
/// a locked device would look like a missing credential, and the obvious response to a
/// missing credential is to ask for it again — or, worse, to clear and re-provision it,
/// which deletes a perfectly good token.
///
/// That last failure is documented rather than hypothetical: on iOS a background launch
/// with the device locked returns `errSecInteractionNotAllowed`, and a keychain *delete*
/// succeeds even when a read did not.
@Suite("Provider availability")
struct ProviderAvailabilityTests {

    private static let instanceID = ProviderInstanceID(rawValue: "pi-1")
    private static let reference = CredentialReference(id: "cred-1")

    private func instance(credential: CredentialReference? = ProviderAvailabilityTests.reference) -> ProviderInstance {
        ProviderInstance(
            id: Self.instanceID,
            providerID: .deepSeek,
            displayName: "DeepSeek",
            baseURL: URL(string: "https://api.deepseek.com"),
            configRevision: .initial,
            credentialReference: credential
        )
    }

    private func makeCredentials(_ secrets: InMemorySecretBackend) -> CredentialStore {
        CredentialStore(secrets: secrets, metadataRepository: InMemoryCredentialMetadataRepository())
    }

    // MARK: - The four states

    @Test("an instance with no credential reference is missing, not invalid")
    func noReferenceIsMissing() throws {
        let availability = try ProviderAvailabilityResolver.resolve(
            instance: instance(credential: nil),
            credentials: makeCredentials(InMemorySecretBackend()),
            verdict: nil
        )
        #expect(availability == .credentialMissing)
    }

    @Test("a provisioned, readable credential is available")
    func provisionedIsAvailable() throws {
        let credentials = makeCredentials(InMemorySecretBackend())
        try credentials.provision(SecretValue("sk-1"), as: Self.reference)

        let availability = try ProviderAvailabilityResolver.resolve(
            instance: instance(),
            credentials: credentials,
            verdict: .accepted
        )
        #expect(availability == .available)
        #expect(availability.isUsable)
    }

    @Test("an unreadable credential is temporarily unavailable, not missing")
    func unreadableIsTemporarilyUnavailable() throws {
        let secrets = InMemorySecretBackend()
        let credentials = makeCredentials(secrets)
        try credentials.provision(SecretValue("sk-1"), as: Self.reference)
        secrets.unreadableReferences = [Self.reference.id]

        let availability = try ProviderAvailabilityResolver.resolve(
            instance: instance(),
            credentials: credentials,
            verdict: .accepted
        )

        guard case .credentialTemporarilyUnavailable = availability else {
            Issue.record(
                """
                expected .credentialTemporarilyUnavailable, got \(availability). Collapsing \
                this into .credentialMissing is how a background launch ends up deleting a \
                valid token: the delete succeeds even when the read did not.
                """
            )
            return
        }
        #expect(!availability.isUsable)
    }

    @Test("a rejected credential is invalid, even though it is readable")
    func rejectedIsInvalid() throws {
        let credentials = makeCredentials(InMemorySecretBackend())
        try credentials.provision(SecretValue("sk-1"), as: Self.reference)

        // The store is perfectly happy — it can read the credential. Only the provider
        // knows it was revoked, which is why the two answers are combined rather than
        // either being trusted alone.
        let availability = try ProviderAvailabilityResolver.resolve(
            instance: instance(),
            credentials: credentials,
            verdict: .rejected
        )
        #expect(availability == .authenticationRequired(reason: .providerRejected))
    }

    @Test("a logged-out credential is invalid, not missing")
    func loggedOutIsInvalid() throws {
        let credentials = makeCredentials(InMemorySecretBackend())
        try credentials.provision(SecretValue("sk-1"), as: Self.reference)
        try credentials.logout(Self.reference)

        let availability = try ProviderAvailabilityResolver.resolve(
            instance: instance(),
            credentials: credentials,
            verdict: nil
        )
        #expect(
            availability == .authenticationRequired(reason: .loggedOut),
            """
            a logout is a deliberate act by a known user; reporting it as 'missing' loses \
            that. The reason is asserted, not just the case — the two reasons need the same \
            thing from the user, which is exactly why they are easy to merge and why the \
            provenance has to be checked rather than assumed.
            """
        )
    }

    @Test("the three credential states are distinguishable from each other")
    func theStatesDoNotCollapse() throws {
        let secrets = InMemorySecretBackend()
        let credentials = makeCredentials(secrets)

        // Missing.
        let missing = try ProviderAvailabilityResolver.resolve(
            instance: instance(), credentials: credentials, verdict: nil
        )
        try credentials.provision(SecretValue("sk-1"), as: Self.reference)

        // Rejected, via the provider.
        let rejected = try ProviderAvailabilityResolver.resolve(
            instance: instance(), credentials: credentials, verdict: .rejected
        )

        // Temporarily unavailable.
        secrets.unreadableReferences = [Self.reference.id]
        let unavailable = try ProviderAvailabilityResolver.resolve(
            instance: instance(), credentials: credentials, verdict: nil
        )

        // Asserted together, because the requirement is precisely that they are not the
        // same value — each on its own would pass even if two of them were identical.
        #expect(
            Set([missing, rejected, unavailable]).count == 3,
            "expected three distinct states, got \([missing, rejected, unavailable])"
        )
    }

    // MARK: - Storage failures stay typed

    @Test("a storage failure is a typed availability, not a raw throw")
    func storageFailureIsTyped() throws {
        let secrets = InMemorySecretBackend()
        let credentials = makeCredentials(secrets)
        try credentials.provision(SecretValue("sk-1"), as: Self.reference)
        secrets.failedReferences = [Self.reference.id]

        // The exact typed state. The user has to act, and it must not be reported
        // as a logout or a rejection: neither happened, and both would send the
        // user to fix the wrong thing.
        let availability = try ProviderAvailabilityResolver.resolve(
            instance: instance(), credentials: credentials, verdict: nil
        )
        #expect(
            availability == .authenticationRequired(reason: .storageFailed),
            "expected .authenticationRequired(.storageFailed), got \(availability)"
        )
    }

    // MARK: - FakeProvider

    @Test("the fake provider answers a known model")
    func fakeProviderKnowsItsModels() {
        let provider = FakeProvider(modelNames: ["fake-model", "fake-model-mini"])
        let instance = instance(credential: nil)

        let descriptor = provider.descriptor(for: ModelID(rawValue: "fake-model"), in: instance)
        #expect(descriptor?.displayName == "fake-model")
        #expect(
            descriptor?.providerInstanceID == instance.id,
            "a descriptor must belong to the instance it was asked about"
        )
    }

    @Test("the fake provider fails closed on an unknown model")
    func fakeProviderFailsClosed() {
        let provider = FakeProvider(modelNames: ["fake-model"])

        // `nil`, not a permissive default. A run proceeding against a model nobody
        // described is worse than a run that cannot start — the notes are explicit that
        // unknown capability must not be guessed.
        #expect(provider.descriptor(for: ModelID(rawValue: "does-not-exist"), in: instance(credential: nil)) == nil)
    }

    @Test("the fake provider conforms to the same protocol a real one will")
    func fakeProviderUsesTheSharedAbstraction() {
        // Compile-time. A fake that satisfied some narrower protocol of its own would
        // let the tests pass while proving nothing about the seam a real adapter uses.
        let provider: any ModelProvider = FakeProvider()
        #expect(provider.id == .deepSeek)
        #expect(!provider.knownModels(for: instance(credential: nil)).isEmpty)
    }

    @Test("descriptors are re-stamped with the instance that asked")
    func descriptorsBelongToTheAskedInstance() {
        let provider = FakeProvider(instanceID: ProviderInstanceID(rawValue: "other"), modelNames: ["m"])
        let asked = instance(credential: nil)

        let models = provider.knownModels(for: asked)
        #expect(
            models.allSatisfy { $0.providerInstanceID == asked.id },
            "an instance must not be handed descriptors belonging to another one"
        )
    }

    @Test("the provider layer stays Sendable")
    func providerTypesAreSendable() {
        func requireSendable<T: Sendable>(_: T.Type) {}
        requireSendable(ProviderInstance.self)
        requireSendable(ProviderID.self)
        requireSendable(ProviderInstanceID.self)
        requireSendable(ModelID.self)
        requireSendable(ModelDescriptor.self)
        requireSendable(ConfigRevision.self)
        requireSendable(ProviderAvailability.self)
        requireSendable(FakeProvider.self)
    }
}

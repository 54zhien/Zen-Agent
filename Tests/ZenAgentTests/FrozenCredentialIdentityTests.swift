import Foundation
import Testing

@testable import ZenAgent

/// Product invariant: **a run goes out under the credential it was frozen against, and
/// under no other.**
///
/// This suite exists because of a specific hole. The seed used to record only a binding
/// *generation*, and validation looked that generation up on whatever credential the
/// instance happened to point at by then. Generation 1 exists on every freshly
/// provisioned credential, so:
///
///     freeze A at generation 1  →  attach a brand-new credential B  →  B is also at
///     generation 1  →  every check passes  →  the request goes out under B
///
/// Nothing about that is visible in the instance's `configRevision` either, because
/// attaching a credential is deliberately not a configuration edit. The identity has to
/// be frozen itself, which is what `CredentialBindingSnapshot` is — and these tests are
/// what keeps it frozen.
@Suite("Frozen credential identity")
struct FrozenCredentialIdentityTests {

    private static let credentialA = CredentialReference(id: "cred-a")
    private static let credentialB = CredentialReference(id: "cred-b")
    private static let instanceID = ProviderInstanceID(rawValue: "pi-1")
    private static let modelID = ModelID(rawValue: "deepseek-flash")

    // MARK: - Fixture

    struct Fixture {
        let store: PersistenceStore
        let credentials: CredentialStore
        let instance: ProviderInstance
        let seed: RequestConfigSeed

        /// Runs dispatch validation the way the provider does.
        ///
        /// `FrozenCredentialIdentityTests.modelID` rather than `Self.modelID`: inside this
        /// nested type `Self` means `Fixture`, which has no such member.
        func validate(against instance: ProviderInstance? = nil) -> ProviderError? {
            do {
                try FrozenConfiguration.validate(
                    seed: seed,
                    modelID: FrozenCredentialIdentityTests.modelID,
                    instance: instance ?? self.instance,
                    credentials: credentials,
                    resolvedEndpoint: DeepSeekProvider.resolvedEndpoint(for: instance ?? self.instance)
                )
                return nil
            } catch let error as ProviderError {
                return error
            } catch {
                Issue.record("expected a ProviderError, got \(error)")
                return nil
            }
        }
    }

    /// Instance pointing at credential A, with both credentials provisioned.
    ///
    /// Both are freshly provisioned, so **both are at generation 1** — which is the
    /// whole reason the reference has to be part of the snapshot.
    private func makeFixture() throws -> Fixture {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let credentials = CredentialStore(secrets: InMemorySecretBackend(), metadataRepository: store)

        let instance = ProviderInstance(
            id: Self.instanceID,
            providerID: .deepSeek,
            displayName: "DeepSeek",
            baseURL: URL(string: "https://api.deepseek.com"),
            configRevision: .initial,
            credentialReference: Self.credentialA
        )
        try store.createProviderInstance(instance)

        try credentials.provision(SecretValue("sk-a"), as: Self.credentialA, principalFingerprint: "acct-a")
        try credentials.provision(SecretValue("sk-b"), as: Self.credentialB, principalFingerprint: "acct-b")

        // What Send freezes: the reference *and* the generation.
        let seed = RequestConfigSeed(
            instance: instance,
            modelID: Self.modelID,
            credentialBinding: CredentialBindingSnapshot(reference: Self.credentialA, generation: 1),
            resolvedEndpoint: DeepSeekProvider.resolvedEndpoint(for: instance)
        )
        return Fixture(store: store, credentials: credentials, instance: instance, seed: seed)
    }

    // MARK: - The hole

    @Test("attaching a different credential at the same generation is refused")
    func differentCredentialSameGenerationIsRefused() throws {
        let f = try makeFixture()
        #expect(f.validate() == nil, "the frozen configuration must validate before anything moves")

        // A brand-new credential. Same generation — that is the point.
        let moved = try f.store.attachCredential(
            Self.credentialB,
            toInstance: Self.instanceID,
            expectedEditRevision: f.instance.editRevision
        )
        #expect(moved.credentialReference == Self.credentialB)
        #expect(
            try f.credentials.metadata(for: Self.credentialB)?.bindingGeneration == 1,
            "credential B must be at generation 1, or this test would pass for the wrong reason"
        )

        // And the instance's revision must NOT have moved, or the older revision check
        // would be catching this instead and the reference check would go untested.
        #expect(
            moved.configRevision == f.seed.providerConfigRevision,
            "attaching a credential is not a configuration edit, so the revision is unchanged — which is exactly why the seed has to name the credential itself"
        )

        let outcome = f.validate(against: moved)
        guard case .configurationMismatch = outcome else {
            Issue.record(
                """
                expected a refusal, got \(String(describing: outcome)). A run frozen \
                against credential A went out under credential B: same generation, \
                different principal, and nothing else in the seed can tell.
                """
            )
            return
        }
    }

    @Test("a rebind to a different principal is refused")
    func rebindIsRefused() throws {
        let f = try makeFixture()
        try f.credentials.rebind(SecretValue("sk-a2"), as: Self.credentialA, principalFingerprint: "acct-other")

        // Same reference, moved generation. The reference check passes and the
        // generation check is what catches this one.
        guard case .configurationMismatch = f.validate() else {
            Issue.record("expected a refusal after a rebind")
            return
        }
    }

    @Test("a logout is refused")
    func logoutIsRefused() throws {
        let f = try makeFixture()
        try f.credentials.logout(Self.credentialA)

        guard case .configurationMismatch = f.validate() else {
            Issue.record("expected a refusal after a logout")
            return
        }
    }

    @Test("a detached credential is refused")
    func detachIsRefused() throws {
        let f = try makeFixture()
        let detached = try f.store.attachCredential(
            nil,
            toInstance: Self.instanceID,
            expectedEditRevision: f.instance.editRevision
        )
        #expect(detached.credentialReference == nil)

        guard case .configurationMismatch = f.validate(against: detached) else {
            Issue.record("expected a refusal once the instance has no credential")
            return
        }
    }

    // MARK: - What must still work

    @Test("a refresh keeps the same binding and still matches")
    func refreshStillMatches() throws {
        let f = try makeFixture()

        // A refresh is a new token for the *same* principal. The generation is
        // deliberately unchanged, so a run that was already in flight stays valid —
        // refusing here would kill runs for an operation that changed nothing about
        // whose account it is.
        try f.credentials.refresh(SecretValue("sk-a-rotated"), for: Self.credentialA)

        #expect(
            f.validate() == nil,
            "a token refresh must not invalidate a run that was frozen against the same binding"
        )
        #expect(try f.credentials.metadata(for: Self.credentialA)?.bindingGeneration == 1)
    }

    // MARK: - The seed itself

    @Test("the seed names the credential and carries no secret")
    func seedCarriesIdentityNotMaterial() throws {
        let f = try makeFixture()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode(f.seed), as: UTF8.self)

        #expect(json.contains(Self.credentialA.id), "the seed must name which credential it was frozen against")
        #expect(!json.contains("sk-a"), "and must not carry the material")
        #expect(!json.contains("sk-b"))
    }

    // MARK: - The write path cannot be bypassed

    @Test("creating an instance whose id is taken is refused rather than overwriting it")
    func createRefusesAnExistingID() throws {
        let f = try makeFixture()

        // The generic upsert this replaced would have silently rewritten the row —
        // with whatever revision the caller passed. That is how an instance could be
        // changed without its revision moving.
        var impostor = f.instance
        impostor.baseURL = URL(string: "https://somewhere-else.example.com")
        impostor.configRevision = .initial

        var failure: Error?
        do {
            try f.store.createProviderInstance(impostor)
        } catch {
            failure = error
        }

        #expect(failure as? PersistenceError == .providerInstanceAlreadyExists(Self.instanceID))
        #expect(
            try f.store.providerInstance(id: Self.instanceID)?.baseURL?.absoluteString == "https://api.deepseek.com",
            "the refused create must not have written anything"
        )
    }
}

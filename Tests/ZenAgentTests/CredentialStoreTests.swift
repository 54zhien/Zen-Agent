import Foundation
import Testing

@testable import ZenAgent

/// Product invariant: **a credential's binding identity is not its reference id.**
///
/// A logout or an account change leaves the id identical. So a paused run comparing only
/// the id would carry on against a different principal — the exact thing
/// `Provider 与模型.md:51` forbids. The generation counter is what makes that
/// distinguishable, and these tests are mostly about its rules.
///
/// Every test here runs against **both** backends: an in-memory pair, and the real
/// Keychain plus real GRDB. The rules live once in `CredentialStore`, above the two
/// seams, so if the fake and the real store could disagree the tests would say so
/// rather than the fake quietly proving nothing.
@Suite("Credential store")
struct CredentialStoreTests {

    /// Which pair of implementations to run against.
    enum Backend: String, CaseIterable, Sendable {
        case inMemory
        case keychainAndGRDB

        /// A fresh store. The Keychain one gets a unique service per call, so items from
        /// one test can never be seen by another.
        func makeStore() throws -> CredentialStore {
            switch self {
            case .inMemory:
                return CredentialStore(
                    secrets: InMemorySecretBackend(),
                    metadataRepository: InMemoryCredentialMetadataRepository()
                )
            case .keychainAndGRDB:
                return CredentialStore(
                    secrets: KeychainSecretBackend(service: "zen-test-\(UUID().uuidString)"),
                    metadataRepository: PersistenceStore(database: try ZenDatabase.inMemory())
                )
            }
        }
    }

    private static let reference = CredentialReference(id: "deepseek-1")

    private func secret(_ text: String) -> SecretValue { SecretValue(text) }

    // MARK: - Provision and resolve

    @Test("provision then resolve returns the secret", arguments: Backend.allCases)
    func provisionThenResolve(backend: Backend) throws {
        let store = try backend.makeStore()
        try store.provision(secret("sk-first"), as: Self.reference)

        #expect(try store.resolve(Self.reference)?.revealed == "sk-first")
        #expect(try store.metadata(for: Self.reference)?.bindingGeneration == 1)
        #expect(try store.metadata(for: Self.reference)?.status == .active)
    }

    @Test("provisioning an existing reference is refused", arguments: Backend.allCases)
    func provisioningTwiceIsRefused(backend: Backend) throws {
        let store = try backend.makeStore()
        try store.provision(secret("sk-first"), as: Self.reference)

        var failure: Error?
        do {
            try store.provision(secret("sk-second"), as: Self.reference)
        } catch {
            failure = error
        }

        // Refused rather than silently overwritten, so the caller has to say whether
        // this is a token rotation (refresh) or a different account (rebind). Those have
        // different consequences for paused runs, and this layer cannot guess which.
        #expect(failure as? CredentialError == .alreadyExists(Self.reference))
        #expect(try store.resolve(Self.reference)?.revealed == "sk-first")
    }

    // MARK: - Update

    @Test("refresh replaces the secret but not the binding", arguments: Backend.allCases)
    func refreshKeepsTheBinding(backend: Backend) throws {
        let store = try backend.makeStore()
        try store.provision(secret("sk-first"), as: Self.reference, principalFingerprint: "acct-a")

        try store.refresh(secret("sk-rotated"), for: Self.reference)

        #expect(try store.resolve(Self.reference)?.revealed == "sk-rotated")
        #expect(
            try store.metadata(for: Self.reference)?.bindingGeneration == 1,
            """
            a token rotation must not bump the generation. If it did, every rotation \
            would invalidate every paused run — and nothing about *who* the credential \
            belongs to changed.
            """
        )
        #expect(try store.metadata(for: Self.reference)?.principalFingerprint == "acct-a")
        #expect(try store.matchesBinding(Self.reference, generation: 1))
    }

    @Test("rebind changes the binding and keeps the reference id", arguments: Backend.allCases)
    func rebindBumpsTheBinding(backend: Backend) throws {
        let store = try backend.makeStore()
        try store.provision(secret("sk-first"), as: Self.reference, principalFingerprint: "acct-a")

        try store.rebind(secret("sk-other-account"), as: Self.reference, principalFingerprint: "acct-b")

        #expect(try store.metadata(for: Self.reference)?.bindingGeneration == 2)
        #expect(try store.metadata(for: Self.reference)?.principalFingerprint == "acct-b")
        #expect(try store.resolve(Self.reference)?.revealed == "sk-other-account")

        // The check a recovering run makes. The id is unchanged, so only this can tell
        // it that the credential now belongs to somebody else.
        #expect(
            try !store.matchesBinding(Self.reference, generation: 1),
            """
            a run frozen against generation 1 must not match after a rebind. This is the \
            check that stops a suspended run from silently continuing on a new account.
            """
        )
        #expect(try store.matchesBinding(Self.reference, generation: 2))
    }

    // MARK: - Failed rebind

    @Test("a rebind whose metadata write fails must not hand the new secret to the old generation")
    func failedRebindDoesNotLeakSecret() throws {
        // In-memory pair only: the Keychain backend has no way to fail a *subsequent*
        // metadata write on demand. The rule being pinned lives in `CredentialStore`,
        // above both seams — that is the whole point of the two-backend split.
        let metadata = InMemoryCredentialMetadataRepository()
        let store = CredentialStore(secrets: InMemorySecretBackend(), metadataRepository: metadata)
        try store.provision(secret("sk-first"), as: Self.reference)

        metadata.failNextSave = true
        var failure: Error?
        do {
            try store.rebind(secret("sk-other-account"), as: Self.reference, principalFingerprint: "acct-b")
        } catch {
            failure = error
        }
        #expect(failure != nil, "the rebind must surface the metadata failure")

        #expect(
            try store.resolve(Self.reference)?.revealed != "sk-other-account",
            """
            a run frozen against generation 1 must never receive the new account's \
            secret. The rebind writes the secret first and the metadata second, so a \
            failed metadata write leaves the new principal's token readable under the \
            old generation — the exact two-step hole this test probes.
            """
        )
        #expect(
            try store.metadata(for: Self.reference)?.bindingGeneration == 1,
            "the metadata must not have moved past the failed write"
        )
    }

    // MARK: - Logout

    @Test("logout removes the secret and bumps the binding", arguments: Backend.allCases)
    func logoutRemovesAndBumps(backend: Backend) throws {
        let store = try backend.makeStore()
        try store.provision(secret("sk-first"), as: Self.reference, principalFingerprint: "acct-a")

        try store.logout(Self.reference)

        #expect(try store.metadata(for: Self.reference)?.bindingGeneration == 2)
        #expect(try store.metadata(for: Self.reference)?.status == .authenticationRequired)

        var failure: Error?
        do {
            _ = try store.resolve(Self.reference)
        } catch {
            failure = error
        }
        #expect(
            failure as? CredentialError == .authenticationRequired(Self.reference),
            "a logged-out credential must be distinguishable from one that never existed"
        )
    }

    @Test("logout keeps the metadata so 'logged out' and 'never existed' differ", arguments: Backend.allCases)
    func logoutKeepsMetadata(backend: Backend) throws {
        let store = try backend.makeStore()
        try store.provision(secret("sk-first"), as: Self.reference)
        try store.logout(Self.reference)

        #expect(
            try store.metadata(for: Self.reference) != nil,
            "keeping the record is what lets a run tell that the binding moved rather than that it vanished"
        )
        #expect(try store.metadata(for: CredentialReference(id: "never-used")) == nil)
    }

    // MARK: - Absence

    @Test("resolving an unknown reference returns nil rather than throwing", arguments: Backend.allCases)
    func unknownReferenceIsNil(backend: Backend) throws {
        let store = try backend.makeStore()

        // `nil` means "there genuinely is none". A credential that exists but cannot be
        // read is a different answer — see the test below.
        #expect(try store.resolve(CredentialReference(id: "never-provisioned")) == nil)
    }

    @Test("refresh and rebind on an unknown reference are refused", arguments: Backend.allCases)
    func updatingUnknownReferenceIsRefused(backend: Backend) throws {
        let store = try backend.makeStore()
        let unknown = CredentialReference(id: "never-provisioned")

        var refreshFailure: Error?
        do { try store.refresh(secret("sk"), for: unknown) } catch { refreshFailure = error }
        #expect(refreshFailure as? CredentialError == .notFound(unknown))

        var rebindFailure: Error?
        do { try store.rebind(secret("sk"), as: unknown, principalFingerprint: "x") } catch { rebindFailure = error }
        #expect(rebindFailure as? CredentialError == .notFound(unknown))
    }

    @Test("an unreadable credential is not reported as missing in-memory")
    func unreadableIsNotMissing() throws {
        // The Keychain can produce this state — a locked device during a background
        // launch returns `errSecInteractionNotAllowed`. The fake reproduces it so the
        // rule is testable without a locked device.
        let secrets = InMemorySecretBackend()
        let store = CredentialStore(
            secrets: secrets,
            metadataRepository: InMemoryCredentialMetadataRepository()
        )
        try store.provision(secret("sk-first"), as: Self.reference)

        secrets.unreadableReferences = [Self.reference.id]

        var failure: Error?
        do {
            _ = try store.resolve(Self.reference)
        } catch {
            failure = error
        }

        guard let error = failure as? CredentialError else {
            Issue.record("expected .unavailable, got \(String(describing: failure))")
            return
        }
        switch error {
        case .unavailable:
            break // expected
        default:
            Issue.record(
                """
                expected .unavailable, got \(error). Reporting an unreadable credential as \
                missing is how a background launch deletes a valid token: the delete \
                succeeds even when the read did not.
                """
            )
        }
    }

    @Test("a backend failure must surface as a typed credential error, not a raw backend error")
    func failedBackendIsTyped() throws {
        let secrets = InMemorySecretBackend()
        let store = CredentialStore(
            secrets: secrets,
            metadataRepository: InMemoryCredentialMetadataRepository()
        )
        try store.provision(secret("sk-first"), as: Self.reference)

        secrets.failedReferences = [Self.reference.id]

        var failure: Error?
        do {
            _ = try store.resolve(Self.reference)
        } catch {
            failure = error
        }

        // Typed, not raw. The caller must never see a `SecretBackendError` — the
        // negative shape keeps this compiling before the typed case exists; the
        // fix upgrades it to the exact case. Folding this into `unavailable` would
        // also be wrong: that promises "wait and try again", and damaged storage
        // does not recover by waiting.
        #expect(
            failure is CredentialError,
            "expected a CredentialError, got \(String(describing: failure)) — a backend failure escaping raw is an untyped leak"
        )
        #expect(!(failure is SecretBackendError))
    }
}

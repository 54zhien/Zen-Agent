import Foundation
import Testing
@testable import ZenAgent

@Suite("Environment owned provisioning recovery")
struct EnvironmentProvisionFailureTests {
    @Test("an ambiguous metadata failure retains durable ownership and later removes unbound Keychain bytes")
    func ambiguousProvisionIsRecoverable() async throws {
        let url = try Fixtures.scratchPath(name: "ambiguous-environment-provision.sqlite")
        defer { Fixtures.cleanUp(url) }
        let backend = InMemorySecretBackend()
        let reference: CredentialReference
        do {
            let store = PersistenceStore(database: try ZenDatabase.open(at: url.path))
            let metadata = AmbiguousEnvironmentMetadata(store: store)
            let credentials = CredentialStore(secrets: backend, metadataRepository: metadata)
            let environment = EnvironmentRuntime(store: store, credentials: credentials)
            do {
                _ = try await environment.saveSecret(key: "AUTH", value: SecretValue("fixture-ambiguous-provision"))
                Issue.record("Expected the real metadata publication failure")
            } catch let error as EnvironmentError {
                #expect(error == .validationUnavailable || error == .cleanupPending)
            }
            reference = try #require(metadata.attemptedReference)
            // The real CredentialStore must conservatively retain bytes while its
            // post-failure metadata read is unavailable. This proves that window.
            #expect(backend.storedSecret(for: reference, generation: 1) != nil)
            #expect(try environment.list().isEmpty)
            #expect(try environment.pendingCleanupCount() == 1)
        }
        // Reopen with fresh runtime/metadata owners, as after process death.
        let reopened = PersistenceStore(database: try ZenDatabase.open(at: url.path))
        let credentials = CredentialStore(secrets: backend, metadataRepository: reopened)
        let environment = EnvironmentRuntime(store: reopened, credentials: credentials)
        #expect(try environment.pendingCleanupCount() == 1)
        try environment.retryCredentialCleanup()
        #expect(try credentials.metadata(for: reference) == nil)
        #expect(backend.storedSecret(for: reference, generation: 1) == nil)
        #expect(try environment.pendingCleanupCount() == 0)
    }
}

private final class AmbiguousEnvironmentMetadata: CredentialMetadataRepository, @unchecked Sendable {
    let store: PersistenceStore
    private let lock = NSLock()
    private var attempted: CredentialReference?
    private var unavailable = true

    init(store: PersistenceStore) { self.store = store }
    var attemptedReference: CredentialReference? { lock.withLock { attempted } }
    func loadMetadata(for reference: CredentialReference) throws -> CredentialMetadata? {
        if lock.withLock({ unavailable && attempted == reference }) { throw SimulatedMetadataWriteFailure() }
        return try store.loadMetadata(for: reference)
    }
    func saveMetadata(_ metadata: CredentialMetadata) throws {
        let fail = lock.withLock { attempted = metadata.reference; return unavailable }
        if fail { throw SimulatedMetadataWriteFailure() }
        try store.saveMetadata(metadata)
    }
    func deleteMetadata(for reference: CredentialReference) throws { try store.deleteMetadata(for: reference) }
}

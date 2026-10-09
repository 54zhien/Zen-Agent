import Foundation
import Testing
@testable import ZenAgent

@Suite("Settings-owned credential provisioning")
struct SettingsCredentialProvisionTests {
    @Test("failed metadata publication cannot strand a newly owned secret")
    func failedProvisionCleansOnlyItsNewReference() throws {
        let metadata = InMemoryCredentialMetadataRepository()
        let backend = InMemorySecretBackend()
        let credentials = CredentialStore(secrets: backend, metadataRepository: metadata)
        let existing = CredentialReference(id: "settings-existing-reference")
        let fresh = CredentialReference(id: "settings-failed-owned-reference")
        try credentials.provision(SecretValue("retained-fixture-secret"), as: existing,
            principalFingerprint: nil, at: Fixtures.epoch)
        metadata.failNextSave = true
        var refused = false
        do {
            try credentials.provision(SecretValue("unpublished-fixture-secret"), as: fresh,
                principalFingerprint: nil, at: Fixtures.epoch)
        } catch { refused = true }
        #expect(refused)
        #expect(try credentials.metadata(for: fresh) == nil)
        #expect(try backend.load(fresh, generation: 1) == nil)
        #expect(try credentials.resolve(existing)?.revealed == "retained-fixture-secret")
        #expect(try credentials.metadata(for: existing)?.bindingGeneration == 1)
    }

    @Test("a metadata write that committed before reporting failure retains its published secret")
    func uncertainPublicationCannotDeleteAReferencedSecret() throws {
        let metadata = CommittedThenRefusingCredentialMetadata()
        let backend = InMemorySecretBackend()
        let credentials = CredentialStore(secrets: backend, metadataRepository: metadata)
        let reference = CredentialReference(id: "settings-committed-owned-reference")
        do {
            try credentials.provision(SecretValue("published-fixture-secret"), as: reference,
                principalFingerprint: nil, at: Fixtures.epoch)
        } catch {}
        #expect(try credentials.metadata(for: reference)?.status == .active)
        #expect(try credentials.resolve(reference)?.revealed == "published-fixture-secret")
        #expect(try backend.load(reference, generation: 1)?.revealed == "published-fixture-secret")
    }

    @Test("unreadable publication state is not proof that an owned secret is unreferenced")
    func unreadableMetadataPreservesTheUncertainSecret() throws {
        let metadata = UnreadableAfterRefusingCredentialMetadata()
        let backend = InMemorySecretBackend()
        let credentials = CredentialStore(secrets: backend, metadataRepository: metadata)
        let reference = CredentialReference(id: "settings-unreadable-owned-reference")
        var refused = false
        do {
            try credentials.provision(SecretValue("uncertain-fixture-secret"), as: reference,
                principalFingerprint: nil, at: Fixtures.epoch)
        } catch { refused = true }
        #expect(refused)
        #expect(try backend.load(reference, generation: 1)?.revealed == "uncertain-fixture-secret")
    }
}

private struct CommittedThenRefusingCredentialMetadata: CredentialMetadataRepository {
    let storage = InMemoryCredentialMetadataRepository()

    func loadMetadata(for reference: CredentialReference) throws -> CredentialMetadata? {
        try storage.loadMetadata(for: reference)
    }
    func saveMetadata(_ metadata: CredentialMetadata) throws {
        try storage.saveMetadata(metadata)
        throw SimulatedMetadataWriteFailure()
    }
    func deleteMetadata(for reference: CredentialReference) throws {
        try storage.deleteMetadata(for: reference)
    }
}

private final class UnreadableAfterRefusingCredentialMetadata: CredentialMetadataRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var publicationFailed = false

    func loadMetadata(for reference: CredentialReference) throws -> CredentialMetadata? {
        lock.lock()
        defer { lock.unlock() }
        if publicationFailed { throw SimulatedMetadataWriteFailure() }
        return nil
    }
    func saveMetadata(_ metadata: CredentialMetadata) throws {
        lock.lock()
        publicationFailed = true
        lock.unlock()
        throw SimulatedMetadataWriteFailure()
    }
    func deleteMetadata(for reference: CredentialReference) throws {
        throw SimulatedMetadataWriteFailure()
    }
}

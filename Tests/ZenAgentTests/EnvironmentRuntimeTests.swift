import Foundation
import Testing
@testable import ZenAgent

@Suite("Stage8 Environment credential and revision boundary")
struct EnvironmentRuntimeTests {
    private func fixture() throws -> (PersistenceStore, InMemorySecretBackend, CredentialStore, EnvironmentRuntime) {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let backend = InMemorySecretBackend()
        let credentials = CredentialStore(secrets: backend, metadataRepository: store)
        return (store, backend, credentials, EnvironmentRuntime(store: store, credentials: credentials))
    }

    @Test("plain edits pin historical revisions, reject stale editors and scope duplicates")
    func immutablePlain() throws {
        let (_, _, _, runtime) = try fixture()
        let maybeFirst = try? runtime.savePlain(key: "LANGUAGE", value: "中文")
        #expect(maybeFirst != nil)
        guard let first = maybeFirst else { return }
        let next = try runtime.savePlain(id: first.id, expectedRevisionID: first.revisionID, key: "LANGUAGE", value: "English")
        #expect(next.revisionID != first.revisionID)
        #expect(try runtime.resolveFrozen([first.reference]).first?.value == .plain("中文"))
        #expect(throws: EnvironmentError.editConflict) {
            try runtime.savePlain(id: first.id, expectedRevisionID: first.revisionID, key: "LANGUAGE", value: "stale")
        }
        #expect(throws: EnvironmentError.duplicateKey) { try runtime.savePlain(key: "LANGUAGE", value: "duplicate") }
    }

    @Test("Secret writes preserve old bindings through ordinary replacement and never encode the bytes")
    func secretVersions() throws {
        let (_, backend, credentials, runtime) = try fixture()
        let firstValue = "fixture-env-credential-old"
        let maybeFirst = try? runtime.saveSecret(key: "SERVICE_AUTH", value: SecretValue(firstValue))
        #expect(maybeFirst != nil)
        guard let first = maybeFirst, case .secret(let firstBinding) = first.value else { return }
        #expect(try credentials.resolve(frozenReference: firstBinding.reference, generation: firstBinding.generation)?.revealed == firstValue)
        let next = try runtime.saveSecret(id: first.id, expectedRevisionID: first.revisionID, key: "SERVICE_AUTH", value: SecretValue("fixture-env-credential-new"))
        guard case .secret(let nextBinding) = next.value else { Issue.record("replacement must remain a reference"); return }
        #expect(firstBinding.reference != nextBinding.reference)
        #expect(backend.storedSecret(for: firstBinding.reference, generation: firstBinding.generation) == firstValue)
        #expect(try runtime.resolveFrozen([first.reference]).first?.value == first.value)
        let data = try JSONEncoder().encode(first.value)
        #expect(!String(decoding: data, as: UTF8.self).contains(firstValue))
        try credentials.logout(firstBinding.reference)
        #expect(throws: EnvironmentError.erasedDependency) { try runtime.resolveFrozen([first.reference]) }
    }

    @Test("failed stale secret save cannot replace or revoke the committed credential")
    func staleSecretSave() throws {
        let (_, backend, _, runtime) = try fixture()
        let maybeFirst = try? runtime.saveSecret(key: "SERVICE_AUTH", value: SecretValue("fixture-committed"))
        #expect(maybeFirst != nil)
        guard let first = maybeFirst, case .secret(let binding) = first.value else { return }
        #expect(throws: EnvironmentError.editConflict) {
            try runtime.saveSecret(id: first.id, expectedRevisionID: "stale", key: "SERVICE_AUTH", value: SecretValue("fixture-uncommitted"))
        }
        #expect(backend.storedSecret(for: binding.reference, generation: binding.generation) == "fixture-committed")
        #expect(try runtime.list().count == 1)
    }

    @Test("known environment secrets cannot be saved as plain data or Memory")
    func contentBoundary() throws {
        let (store, _, credentials, runtime) = try fixture()
        let value = "fixture-private-environment-value"
        let saved = try? runtime.saveSecret(key: "SERVICE_AUTH", value: SecretValue(value))
        #expect(saved != nil)
        guard saved != nil else { return }
        #expect(throws: EnvironmentError.unsafeContent) { try runtime.savePlain(key: "LANGUAGE", value: value) }
        #expect(throws: MemoryError.unsafeContent) {
            try MemoryRuntime(store: store, credentials: credentials).save(content: "My name is \(value)")
        }
        #expect(throws: EnvironmentError.invalidKey) { try runtime.savePlain(key: "1INVALID", value: "test") }
    }

    @Test("erasure removes every version and revokes owned Secret bytes")
    func erasure() async throws {
        let (_, backend, _, runtime) = try fixture()
        let maybeFirst = try? runtime.saveSecret(key: "SERVICE_AUTH", value: SecretValue("fixture-deleted"))
        #expect(maybeFirst != nil)
        guard let first = maybeFirst, case .secret(let binding) = first.value else { return }
        try await runtime.delete(id: first.id)
        #expect(try runtime.list().isEmpty)
        #expect(backend.storedSecret(for: binding.reference, generation: binding.generation) == nil)
        #expect(throws: EnvironmentError.erasedDependency) { try runtime.resolveFrozen([first.reference]) }
    }
}

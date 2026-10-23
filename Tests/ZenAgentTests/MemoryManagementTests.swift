import Foundation
import GRDB
import Testing
@testable import ZenAgent

@Suite("Memory management")
struct MemoryManagementTests {
    @Test("edits use CAS, pin immutable old versions and delete every version")
    func editAndErase() async throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let runtime = MemoryRuntime(store: store, credentials: nil)
        let first = try runtime.save(content: "我偏好中文回答")
        let second = try runtime.save(id: first.id, expectedRevisionID: first.revisionID, content: "我偏好简洁的中文回答")
        #expect(first.revisionID != second.revisionID)
        #expect(try store.memoryRevision(id: first.revisionID)?.content == first.content)
        #expect(throws: MemoryError.editConflict) {
            try runtime.save(id: first.id, expectedRevisionID: first.revisionID, content: "stale edit")
        }
        try await runtime.delete(id: first.id)
        #expect(try store.memories().isEmpty)
        #expect(try store.memoryRevision(id: first.revisionID) == nil)
        #expect(try store.memoryRevision(id: second.revisionID) == nil)
    }

    @Test("unsafe or unavailable validation never persists a fact")
    func credentials() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let runtime = MemoryRuntime(store: store, credentials: nil)
        #expect(throws: MemoryError.unsafeContent) { try runtime.save(content: "password=fixture") }
        #expect(throws: MemoryError.unsafeContent) { try runtime.save(content: "我的密码是 fixture") }
        #expect(try store.memories().isEmpty)
    }

    @Test("configured credentials and equivalent escaped JSON are refused; unreadable validation fails closed")
    func configuredCredentials() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let backend = InMemorySecretBackend()
        let credentials = CredentialStore(secrets: backend, metadataRepository: InMemoryCredentialMetadataRepository())
        let reference = CredentialReference(id: "memory-test-key")
        try credentials.provision(SecretValue("fixture-private-credential"), as: reference)
        try store.createProviderInstance(ProviderInstance(id: .init(rawValue: "memory-provider"), providerID: .deepSeek,
            displayName: "Memory test", baseURL: nil, configRevision: .initial, credentialReference: reference))
        let runtime = MemoryRuntime(store: store, credentials: credentials)
        #expect(throws: MemoryError.unsafeContent) { try runtime.save(content: "My name is fixture-private-credential") }
        #expect(throws: MemoryError.unsafeContent) { try runtime.save(content: #"{"pa\u0073sword":"fixture"}"#) }
        backend.unreadableReferences = [reference.id]
        #expect(throws: MemoryError.validationUnavailable) { try runtime.save(content: "I work on Windows") }
        #expect(try store.memories().isEmpty)
    }

    @Test("concurrent editors cannot overwrite a newer Memory revision")
    func concurrentSave() async throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let item = try store.saveMemory(content: "I work on Windows")
        let results = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<8 {
                group.addTask {
                    do {
                        _ = try store.saveMemory(id: item.id, expectedRevisionID: item.revisionID,
                            content: "I work on Windows \(index)")
                        return true
                    } catch { return false }
                }
            }
            var count = 0
            for await result in group where result { count += 1 }
            return count
        }
        #expect(results == 1)
        #expect(try store.memories().count == 1)
    }

    @Test("source provenance survives Undo and is marked missing only at finalized deletion")
    func sourceDeletion() throws {
        let database = try ZenDatabase.inMemory()
        let store = PersistenceStore(database: database)
        try database.write { try Fixtures.conversation(id: "source").insert($0) }
        let source = MemorySource(id: "s", conversationID: "source", messageID: nil, kind: .explicitUser, missing: false)
        let item = try store.saveMemory(content: "我使用 Windows 开发", origin: .explicitUser, source: source)
        try store.beginDeletion(conversationID: "source")
        #expect(try store.memories().first?.sources.first?.missing == false)
        try store.undoDeletion(conversationID: "source")
        #expect(try store.memories().first?.sources.first?.missing == false)
        try store.beginDeletion(conversationID: "source")
        try store.finalizeDeletion(conversationID: "source")
        let retained = try #require(store.memories().first)
        #expect(retained.id == item.id)
        #expect(retained.content == item.content)
        #expect(retained.sources.first?.missing == true)
    }

    @Test("disable preserves data and Clear All erases bodies and advances generation")
    func disableAndClear() async throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let runtime = MemoryRuntime(store: store, credentials: nil)
        _ = try runtime.save(content: "我偏好中文回答")
        try runtime.setEnabled(false)
        #expect(try !store.memorySettings().enabled)
        #expect(try store.memories().count == 1)
        let generation = try store.memorySettings().generation
        try await runtime.clear()
        #expect(try store.memories().isEmpty)
        #expect(try store.memorySettings().generation > generation)
        let count = try store.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM memoryRevision") }
        #expect(count == 0)
    }
}

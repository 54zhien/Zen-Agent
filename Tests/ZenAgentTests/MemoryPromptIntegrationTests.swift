import Foundation
import GRDB
import Testing
@testable import ZenAgent

@Suite("Memory actual request and erasure integration")
struct MemoryPromptIntegrationTests {
    @Test("new Runs retrieve current Memory as user context, pin versions and never modify system authority")
    func actualRequests() async throws {
        let fixture = try MemoryPromptFixture.make()
        let memory = MemoryRuntime(store: fixture.store, credentials: fixture.credentials)
        let first = try memory.save(content: "Windows project uses UNIQUE_OLD_FACT")
        let firstRun = try await fixture.send(text: "Help with Windows")
        let requests = await fixture.ledger.requestsSnapshot()
        let request = try #require(requests.first)
        #expect(userContent(request).contains(first.content))
        if let firstMessage = request.messages.first, case .system(let system) = firstMessage { #expect(!system.contains(first.content)) }
        else { Issue.record("Expected existing system boundary") }
        #expect(request.tools.isEmpty)
        let persistedRun = try fixture.store.run(id: firstRun)
        let run = try #require(persistedRun)
        let encoded = try #require(run.executionSnapshot)
        #expect(!encoded.contains(first.content))
        let object = try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any]
        let prompt = object?["prompt"] as? [String: Any]
        let refs = prompt?["memoryReferences"] as? [[String: Any]]
        #expect(refs?.first?["revisionID"] as? String == first.revisionID)
        _ = try memory.save(id: first.id, expectedRevisionID: first.revisionID, content: "Windows project uses UNIQUE_NEW_FACT")
        _ = try await fixture.send(text: "Help with Windows")
        let updatedRequests = await fixture.ledger.requestsSnapshot()
        #expect(userContent(updatedRequests[0]).contains("UNIQUE_OLD_FACT"))
        #expect(userContent(updatedRequests[1]).contains("UNIQUE_NEW_FACT"))
        #expect(!userContent(updatedRequests[1]).contains("UNIQUE_OLD_FACT"))
        try memory.setEnabled(false)
        _ = try await fixture.send(text: "Help with Windows")
        let disabledRequests = await fixture.ledger.requestsSnapshot()
        #expect(!userContent(disabledRequests[2]).contains("UNIQUE_NEW_FACT"))
        #expect(try fixture.store.memories().count == 1)
    }

    @Test("deletion persists invalidate across disk reopening and recovery never resumes it")
    func erasedRecovery() async throws {
        let url = try Fixtures.scratchPath(name: "memory-erased-recovery.sqlite")
        defer { Fixtures.cleanUp(url) }
        let fixture = try MemoryPromptFixture.make(database: ZenDatabase.open(at: url.path))
        let memory = MemoryRuntime(store: fixture.store, credentials: fixture.credentials)
        let item = try memory.save(content: "Windows project uses MEMORY_TO_ERASE")
        let runID = try await fixture.send(text: "Help with Windows")
        let persistedRun = try fixture.store.run(id: runID)
        let run = try #require(persistedRun)
        let snapshotText = try #require(run.executionSnapshot)
        let decoded = try JSONSerialization.jsonObject(with: Data(snapshotText.utf8))
        var object = try #require(decoded as? [String: Any])
        var prompt = try #require(object["prompt"] as? [String: Any])
        prompt["memoryReferences"] = [["memoryID": item.id, "revisionID": item.revisionID]]
        object["prompt"] = prompt
        let snapshot = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        try fixture.store.database.write { db in
            try db.execute(sql: "UPDATE agentRun SET state='suspended',endReason=NULL,recoveryAction='resume',suspendReason='backgrounded',activeSlot=conversationID,executionSnapshot=? WHERE id=?", arguments: [snapshot, runID])
        }
        try await memory.delete(id: item.id)
        #expect(try fixture.store.run(id: runID)?.recoveryAction == .invalidate)
        let reopened = PersistenceStore(database: try ZenDatabase.open(at: url.path))
        try await RunRecovery(store: reopened, credentials: fixture.credentials).recover(runID: runID)
        #expect(try reopened.run(id: runID)?.state == .failed)
        #expect(try reopened.run(id: runID)?.endReason == .dependencyUnavailable)
        #expect(try reopened.memoryRevision(id: item.revisionID) == nil)
        let requests = await fixture.ledger.requestsSnapshot()
        #expect(requests.count == 1)
    }

    private func userContent(_ request: ProviderChatRequest) -> String {
        guard let message = request.messages.last, case .user(let text) = message else { return "" }
        return text
    }
}

struct MemoryPromptFixture {
    let store: PersistenceStore
    let credentials: CredentialStore
    let runtime: ConversationRuntime
    let provider: Stage2ScriptedProvider
    let ledger: Stage2ProviderLedger
    let instanceID: ProviderInstanceID

    static func make(database: ZenDatabase? = nil, registry: ToolRegistry = .empty,
                     scripts: [Stage2ProviderScript] = [.events([.textDelta("Recorded answer"), .finish(.stop)])],
                     onEvent: @escaping @Sendable (AgentEvent) async -> Void = { _ in }) throws -> MemoryPromptFixture {
        let resolved: ZenDatabase
        if let database { resolved = database } else { resolved = try ZenDatabase.inMemory() }
        let store = PersistenceStore(database: resolved)
        let credentials = CredentialStore(secrets: InMemorySecretBackend(), metadataRepository: InMemoryCredentialMetadataRepository())
        let reference = CredentialReference(id: "memory-fixture-credential")
        try credentials.provision(SecretValue("memory-fixture-private-value"), as: reference)
        let instanceID = ProviderInstanceID(rawValue: "memory-fixture-provider")
        if try store.providerInstance(id: instanceID) == nil {
            try store.createProviderInstance(ProviderInstance(id: instanceID, providerID: .deepSeek,
                displayName: "Memory fixture", baseURL: URL(string: "https://memory-fixture.invalid"),
                configRevision: .initial, credentialReference: reference))
        }
        let ledger = Stage2ProviderLedger()
        let provider = Stage2ScriptedProvider(ledger: ledger, scripts: scripts)
        let runtime = ConversationRuntime(store: store, provider: provider, credentials: credentials,
            onEvent: onEvent, toolRegistry: registry)
        return Self(store: store, credentials: credentials, runtime: runtime, provider: provider, ledger: ledger, instanceID: instanceID)
    }

    func command(text: String, conversationID: String = "memory-conversation") -> SendCommand {
        SendCommand(conversationID: conversationID, text: text, providerInstanceID: instanceID,
            modelID: Stage2GateFixture.modelID, maxProviderSteps: 4, submissionID: UUID().uuidString)
    }

    func send(text: String, conversationID: String = "memory-conversation") async throws -> String {
        let runID = try await runtime.start(command(text: text, conversationID: conversationID),
            creatingConversationIfMissing: Fixtures.conversation(id: conversationID))
        try await runtime.waitForCompletion(runID: runID)
        return runID
    }
}

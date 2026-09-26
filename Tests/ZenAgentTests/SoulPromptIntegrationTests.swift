import Foundation
import Testing

@testable import ZenAgent

@Suite("Soul prompt integration")
struct SoulPromptIntegrationTests {
    @Test("the first provider request uses the bound Soul version")
    func firstRequestUsesBoundSoulVersion() async throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let credential = CredentialReference(id: "soul-prompt-test-credential")
        let credentials = CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: InMemoryCredentialMetadataRepository()
        )
        try credentials.provision(SecretValue("soul-prompt-test-secret"), as: credential)

        let instanceID = ProviderInstanceID(rawValue: "soul-prompt-test-provider")
        try store.createProviderInstance(ProviderInstance(
            id: instanceID,
            providerID: .deepSeek,
            displayName: "Soul prompt test provider",
            baseURL: URL(string: "https://soul-prompt.invalid"),
            configRevision: .initial,
            credentialReference: credential
        ))
        try store.database.write { db in
            try Fixtures.conversation(id: "soul-prompt-test-conversation").insert(db)
        }
        try store.createSoul(
            initialVersion: SoulVersionRecord(
                id: "soul-v1",
                instructions: "SOUL VERSION ONE",
                createdAt: Fixtures.epoch
            ),
            at: Fixtures.epoch
        )

        let ledger = Stage2ProviderLedger()
        let provider = Stage2ScriptedProvider(
            ledger: ledger,
            scripts: [.events([.textDelta("response"), .finish(.stop)])]
        )
        let runtime = ConversationRuntime(
            store: store,
            provider: provider,
            credentials: credentials
        )
        let runID = try await runtime.send(SendCommand(
            conversationID: "soul-prompt-test-conversation",
            text: "hello",
            providerInstanceID: instanceID,
            modelID: Stage2GateFixture.modelID,
            maxProviderSteps: Stage2GateFixture.maxProviderSteps,
            submissionID: "soul-prompt-test-submission"
        ))

        let requests = await ledger.requestsSnapshot()
        let request = try #require(requests.first)
        guard let firstMessage = request.messages.first,
              case .system(let systemPrompt) = firstMessage
        else {
            Issue.record("the actual provider request must begin with a system prompt")
            return
        }
        #expect(systemPrompt.contains("SOUL VERSION ONE"))

        let run = try #require(try store.run(id: runID))
        let encodedSnapshot = try #require(run.executionSnapshot)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(encodedSnapshot.utf8)) as? [String: Any]
        )
        #expect(object["soulVersionID"] as? String == "soul-v1")
    }
}
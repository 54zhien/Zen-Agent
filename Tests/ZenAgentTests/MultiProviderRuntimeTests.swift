import Foundation
import Testing

@testable import ZenAgent

@Suite("Multiple provider Runtime routing")
struct MultiProviderRuntimeTests {
    private struct Fixture {
        let store: PersistenceStore
        let credentials: CredentialStore
        let conversationID: String
        let openAIInstance: ProviderInstance
        let deepSeek: FakeProvider
        let openAI: FakeProvider
    }

    private func makeFixture() throws -> Fixture {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let credentials = CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: InMemoryCredentialMetadataRepository()
        )
        let deepSeekReference = CredentialReference(id: "multi-provider-deepseek")
        let openAIReference = CredentialReference(id: "multi-provider-openai")
        try credentials.provision(SecretValue("deepseek-test-key"), as: deepSeekReference)
        try credentials.provision(SecretValue("openai-test-key"), as: openAIReference)

        let conversationID = "multi-provider-\(UUID().uuidString)"
        let openAIInstance = ProviderInstance(
            id: ProviderInstanceID(rawValue: "openai-instance-\(UUID().uuidString)"),
            providerID: .openAI,
            displayName: "OpenAI",
            baseURL: nil,
            configRevision: .initial,
            credentialReference: openAIReference
        )
        try store.createProviderInstance(openAIInstance)
        try store.database.write { db in
            try Fixtures.conversation(id: conversationID).insert(db)
        }

        return Fixture(
            store: store,
            credentials: credentials,
            conversationID: conversationID,
            openAIInstance: openAIInstance,
            deepSeek: FakeProvider(
                id: .deepSeek,
                modelNames: ["deepseek-model"],
                capabilities: [.text, .streaming],
                scriptedEvents: [.textDelta("DeepSeek response"), .finish(.stop)]
            ),
            openAI: FakeProvider(
                id: .openAI,
                instanceID: openAIInstance.id,
                modelNames: ["openai-model"],
                capabilities: [.text, .streaming],
                scriptedEvents: [.textDelta("OpenAI response"), .finish(.stop)]
            )
        )
    }

    private func command(for fixture: Fixture) -> SendCommand {
        SendCommand(
            conversationID: fixture.conversationID,
            text: "route to OpenAI",
            providerInstanceID: fixture.openAIInstance.id,
            modelID: ModelID(rawValue: "openai-model"),
            maxProviderSteps: 4,
            submissionID: "multi-provider-send-\(UUID().uuidString)"
        )
    }

    @Test("new Run selects its instance Provider while both adapters are registered")
    func newRunUsesSelectedProvider() async throws {
        let fixture = try makeFixture()
        let registry = try ModelProviderRegistry(providers: [fixture.deepSeek, fixture.openAI])
        let runtime = ConversationRuntime(
            store: fixture.store,
            providerRegistry: registry,
            credentials: fixture.credentials
        )

        let runID = try await runtime.send(command(for: fixture))
        let run = try #require(try fixture.store.run(id: runID))
        let snapshot = try ExecutionSnapshotCodec.decode(
            #require(run.executionSnapshot)
        )
        let messages = try fixture.store.messages(inConversation: fixture.conversationID)
        let response = try #require(messages.first(where: { $0.role == .assistant }))
        let parts = try fixture.store.parts(ofMessage: response.id)

        #expect(snapshot.providerID == .openAI)
        #expect(snapshot.providerAdapterRevision == fixture.openAI.adapterRevision)
        #expect(try fixture.store.text(ofPart: #require(parts.first).id) == "OpenAI response")
    }

    @Test("reconstruction refuses a missing or changed frozen Provider adapter")
    func frozenReconstructionDoesNotFallback() async throws {
        let fixture = try makeFixture()
        let registry = try ModelProviderRegistry(providers: [fixture.deepSeek, fixture.openAI])
        let runtime = ConversationRuntime(
            store: fixture.store,
            providerRegistry: registry,
            credentials: fixture.credentials
        )
        let runID = try await runtime.send(command(for: fixture))
        let run = try #require(try fixture.store.run(id: runID))
        let snapshot = try ExecutionSnapshotCodec.decode(#require(run.executionSnapshot))

        let missing = try ModelProviderRegistry(providers: [fixture.deepSeek])
        let missingRebuilder = RunRequestRebuilder(
            store: fixture.store,
            providerRegistry: missing,
            toolRegistry: .empty,
            credentials: fixture.credentials
        )
        var missingFailure: Error?
        do {
            _ = try missingRebuilder.initialRequest(for: run, snapshot: snapshot, history: [])
        } catch {
            missingFailure = error
        }
        let missingIsIncompatible: Bool
        if let error = missingFailure as? RunRequestRebuildError,
           case .incompatibleSnapshot = error {
            missingIsIncompatible = true
        } else {
            missingIsIncompatible = false
        }
        #expect(missingIsIncompatible)

        let revised = try ModelProviderRegistry(providers: [
            RevisionedModelProvider(base: fixture.openAI, revision: "openai-responses.v2")
        ])
        let revisedRebuilder = RunRequestRebuilder(
            store: fixture.store,
            providerRegistry: revised,
            toolRegistry: .empty,
            credentials: fixture.credentials
        )
        var revisionFailure: Error?
        do {
            _ = try revisedRebuilder.initialRequest(for: run, snapshot: snapshot, history: [])
        } catch {
            revisionFailure = error
        }
        let revisionIsIncompatible: Bool
        if let error = revisionFailure as? RunRequestRebuildError,
           case .incompatibleSnapshot = error {
            revisionIsIncompatible = true
        } else {
            revisionIsIncompatible = false
        }
        #expect(revisionIsIncompatible)
    }
}

private struct RevisionedModelProvider: ModelProvider {
    let base: any ModelProvider
    let revision: String

    var id: ProviderID { base.id }
    var adapterRevision: String { revision }
    var adapterPromptInstructions: String { base.adapterPromptInstructions }

    func knownModels(for instance: ProviderInstance) -> [ModelDescriptor] {
        base.knownModels(for: instance)
    }

    func descriptor(for modelID: ModelID, in instance: ProviderInstance) -> ModelDescriptor? {
        base.descriptor(for: modelID, in: instance)
    }

    func makeRequestConfigSeed(
        instance: ProviderInstance,
        modelID: ModelID,
        credentialBinding: CredentialBindingSnapshot
    ) throws -> RequestConfigSeed {
        try base.makeRequestConfigSeed(
            instance: instance,
            modelID: modelID,
            credentialBinding: credentialBinding
        )
    }

    func stream(
        _ request: ProviderChatRequest,
        seed: RequestConfigSeed,
        credentials: any CredentialStoring
    ) async throws -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        try await base.stream(request, seed: seed, credentials: credentials)
    }
}

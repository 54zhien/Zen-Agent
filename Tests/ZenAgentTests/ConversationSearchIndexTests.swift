import Foundation
import GRDB
import Testing
@testable import ZenAgent

@Suite("Conversation search index recovery")
struct ConversationSearchIndexTests {
    @Test("the local full text index follows completed visible user and assistant text")
    func completedVisibleTextIsIndexedAndDeletionUndoIsSynchronized() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.database.write { db in
            try Fixtures.conversation(id: "visible-search").insert(db)
            try Fixtures.conversation(id: "hidden-search", lifecycle: .pendingDeletion).insert(db)
            for (id, conversationID, role, state, text) in [
                ("user-complete", "visible-search", MessageRole.user, MessagePartState.completed, "completed user phrase"),
                ("assistant-complete", "visible-search", MessageRole.assistant, MessagePartState.completed, "completed assistant phrase"),
                ("assistant-streaming", "visible-search", MessageRole.assistant, MessagePartState.streaming, "unfinished stream phrase"),
                ("system-complete", "visible-search", MessageRole.system, MessagePartState.completed, "system only phrase"),
                ("hidden-complete", "hidden-search", MessageRole.user, MessagePartState.completed, "hidden conversation phrase"),
            ] {
                let messageID = "message-\(id)"
                try Fixtures.message(id: messageID, conversationID: conversationID, role: role).insert(db)
                var part = Fixtures.textPart(id: "part-\(id)", messageID: messageID, text: text)
                part.state = state
                try part.insert(db)
            }
            try db.execute(sql: """
                INSERT INTO conversationSearch.conversationVectorRecord (
                    profileID, conversationID, partID, chunkIndex, startOffset, endOffset,
                    sourceRevision, contentHash, embedding
                ) VALUES ('profile', 'visible-search', 'part-user-complete', 0, 0, 20, 1, 'hash', x'00000000')
                """)
        }

        #expect(try indexCounts(in: store) == (2, 1))

        #expect(try store.searchConversationSummaries(query: "completed user phrase").items.map(\.id)
            == ["visible-search"])
        #expect(try store.searchConversationSummaries(query: "completed assistant phrase").items.map(\.id)
            == ["visible-search"])
        #expect(try store.searchConversationSummaries(query: "unfinished stream phrase").items.isEmpty)
        #expect(try store.searchConversationSummaries(query: "system only phrase").items.isEmpty)
        #expect(try store.searchConversationSummaries(query: "hidden conversation phrase").items.isEmpty)

        try store.beginDeletion(conversationID: "visible-search")
        #expect(try indexCounts(in: store) == (0, 0))
        try store.undoDeletion(conversationID: "visible-search")
        #expect(try indexCounts(in: store) == (2, 0))

        try store.undoDeletion(conversationID: "hidden-search")
        #expect(try store.searchConversationSummaries(query: "hidden conversation phrase").items.map(\.id)
            == ["hidden-search"])
    }

    private func indexCounts(in store: PersistenceStore) throws -> (Int, Int) {
        try store.database.read { db in
            let fullText = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversationSearch.conversationSearchIndex") ?? 0
            let vectors = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversationSearch.conversationVectorRecord") ?? 0
            return (fullText, vectors)
        }
    }

    @Test("the excluded search database is rebuilt from the protected conversation database")
    func missingDerivedDatabaseIsRebuilt() throws {
        let databaseURL = try Fixtures.scratchPath(name: "conversations.sqlite")
        let searchURL = databaseURL.deletingLastPathComponent().appending(path: "DerivedSearch.sqlite")
        defer { Fixtures.cleanUp(databaseURL) }

        func seedConversation() throws {
            let store = PersistenceStore(database: try ZenDatabase.open(
                at: databaseURL.path,
                searchIndexAt: searchURL.path
            ))
            try store.database.write { db in
                try Fixtures.conversation(id: "restored-search").insert(db)
                try Fixtures.message(id: "restored-message", conversationID: "restored-search").insert(db)
                try Fixtures.textPart(
                    id: "restored-part",
                    messageID: "restored-message",
                    text: "rebuild from source text"
                ).insert(db)
            }
        }

        try seedConversation()
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: searchURL.path + suffix)
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
        }

        let restored = PersistenceStore(database: try ZenDatabase.open(
            at: databaseURL.path,
            searchIndexAt: searchURL.path
        ))
        #expect(try restored.searchConversationSummaries(query: "rebuild from source").items.map(\.id)
            == ["restored-search"])
    }

    @Test("a source and index revision split after interruption is repaired on reopen")
    func revisionMismatchRebuildsTheIndex() throws {
        let databaseURL = try Fixtures.scratchPath(name: "conversations.sqlite")
        let searchURL = databaseURL.deletingLastPathComponent().appending(path: "DerivedSearch.sqlite")
        defer { Fixtures.cleanUp(databaseURL) }

        func seedAndSimulateTheMainDatabaseCommit() throws {
            let store = PersistenceStore(database: try ZenDatabase.open(
                at: databaseURL.path,
                searchIndexAt: searchURL.path
            ))
            try store.database.write { db in
                try Fixtures.conversation(id: "interrupted-search").insert(db)
                try Fixtures.message(id: "interrupted-message", conversationID: "interrupted-search").insert(db)
                try Fixtures.textPart(
                    id: "interrupted-part",
                    messageID: "interrupted-message",
                    text: "recover partial commit"
                ).insert(db)
                try db.execute(sql: "UPDATE main.conversationSearchIndexState SET revision = revision + 1 WHERE id = 1")
            }
        }

        try seedAndSimulateTheMainDatabaseCommit()
        let reopened = PersistenceStore(database: try ZenDatabase.open(
            at: databaseURL.path,
            searchIndexAt: searchURL.path
        ))
        #expect(try reopened.searchConversationSummaries(query: "recover partial commit").items.map(\.id)
            == ["interrupted-search"])
    }

    @Test("semantic search sends only eligible text after submission and ranks the closest session")
    func semanticSearchUsesCompletedVisibleText() async throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let reference = CredentialReference(id: "semantic-search-key")
        let credentials = CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: InMemoryCredentialMetadataRepository()
        )
        try credentials.provision(SecretValue("semantic-search-secret"), as: reference)
        let instance = ProviderInstance(
            id: ProviderInstanceID(rawValue: "semantic-search-account"),
            providerID: .openAI,
            displayName: "Existing OpenAI account",
            baseURL: nil,
            configRevision: .initial,
            credentialReference: reference
        )
        try store.createProviderInstance(instance)

        try store.database.write { db in
            try Fixtures.conversation(id: "travel", title: "Road notes").insert(db)
            try Fixtures.conversation(id: "kitchen", title: "Kitchen notes").insert(db)
            try Fixtures.conversation(id: "hidden", title: "Hidden notes", lifecycle: .pendingDeletion).insert(db)

            let parts: [(String, MessageRole, MessagePartState, MessagePartKind, String)] = [
                ("travel", .user, .completed, .text, "trip across the mountain pass"),
                ("travel", .assistant, .completed, .text, "pack a compass before hiking"),
                ("travel", .assistant, .streaming, .text, "unfinished trail answer"),
                ("travel", .system, .completed, .text, "system-only body"),
                ("travel", .assistant, .completed, .toolResult, "tool-only body"),
                ("kitchen", .user, .completed, .text, "bake fresh bread"),
                ("hidden", .user, .completed, .text, "hidden hiking body"),
            ]
            for (index, value) in parts.enumerated() {
                let (conversationID, role, state, kind, text) = value
                let messageID = "message-\(index)"
                try Fixtures.message(id: messageID, conversationID: conversationID, role: role).insert(db)
                var part = Fixtures.textPart(id: "part-\(index)", messageID: messageID, text: text)
                part.kind = kind
                part.state = state
                try part.insert(db)
            }
        }

        let recorder = SemanticEmbeddingCallRecorder()
        let provider = SemanticTestEmbeddingProvider(recorder: recorder)
        let runtime = ConversationSearchIndexRuntime(store: store, embeddingProvider: provider, credentials: credentials)
        let first = try await runtime.search(query: "find an alpine path", providerInstanceID: instance.id)
        #expect(first.items.first?.id == "travel")
        #expect(try store.searchConversationSummaries(query: "alpine").items.isEmpty)

        let firstInputs = await recorder.calls().flatMap { $0 }
        #expect(firstInputs.contains("find an alpine path"))
        #expect(firstInputs.contains("trip across the mountain pass"))
        #expect(firstInputs.contains("pack a compass before hiking"))
        #expect(firstInputs.contains("bake fresh bread"))
        #expect(!firstInputs.contains(where: { $0.contains("unfinished trail answer") }))
        #expect(!firstInputs.contains(where: { $0.contains("system-only body") }))
        #expect(!firstInputs.contains(where: { $0.contains("tool-only body") }))
        #expect(!firstInputs.contains(where: { $0.contains("hidden hiking body") }))
        #expect(try store.conversationVectorRecords(
            profileID: "openai|semantic-test.v1|semantic-search-account|1|semantic-test|3"
        ).count == 3)

        let second = try await runtime.search(query: "where can I find bread", providerInstanceID: instance.id)
        #expect(second.items.first?.id == "kitchen")
        #expect(await recorder.lastCall() == ["where can I find bread"])
        #expect(try store.conversationSearchSources().contains(where: {
            $0.text == "trip across the mountain pass"
        }))
    }

    @Test("semantic ranking keeps fifty-result capacity beyond the preview window")
    func semanticSearchReturnsRankedResultsPastPreviewWindow() async throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let reference = CredentialReference(id: "semantic-window-key")
        let credentials = CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: InMemoryCredentialMetadataRepository()
        )
        try credentials.provision(SecretValue("semantic-window-secret"), as: reference)
        let instance = ProviderInstance(
            id: ProviderInstanceID(rawValue: "semantic-window-account"),
            providerID: .openAI,
            displayName: "Existing OpenAI account",
            baseURL: nil,
            configRevision: .initial,
            credentialReference: reference
        )
        try store.createProviderInstance(instance)
        let rankedIDs = (0..<6).map { "rank-\($0)" }
        try store.database.write { db in
            for id in rankedIDs {
                try Fixtures.conversation(id: id).insert(db)
                try Fixtures.message(id: "message-\(id)", conversationID: id, role: .user).insert(db)
                let text = id == "rank-0" ? "mountain trail notes" : "unrelated notes for \(id)"
                try Fixtures.textPart(id: "part-\(id)", messageID: "message-\(id)", text: text).insert(db)
            }
        }

        let provider = SemanticTestEmbeddingProvider(recorder: SemanticEmbeddingCallRecorder())
        let runtime = ConversationSearchIndexRuntime(store: store, embeddingProvider: provider, credentials: credentials)
        let page = try await runtime.search(query: "find a mountain trail", providerInstanceID: instance.id)

        #expect(page.items.count == 6)
        #expect(page.items.map(\.id) == ["rank-0", "rank-1", "rank-2", "rank-3", "rank-4", "rank-5"])
    }

    @Test("OpenAI embeddings use the existing account and map results by response index")
    func openAIEmbeddingRequestUsesFrozenCredential() async throws {
        let transport = FakeHTTPTransport()
        let provider = OpenAIEmbeddingProvider(transport: transport)
        let reference = CredentialReference(id: "embedding-provider-key")
        let credentials = CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: InMemoryCredentialMetadataRepository()
        )
        try credentials.provision(SecretValue("embedding-provider-secret"), as: reference)
        let metadata = try #require(try credentials.metadata(for: reference))
        let instance = ProviderInstance(
            id: ProviderInstanceID(rawValue: "embedding-provider-account"),
            providerID: .openAI,
            displayName: "Existing account",
            baseURL: URL(string: "https://openai.example.test/v1"),
            configRevision: .initial,
            credentialReference: reference
        )
        let firstVector = Array(repeating: 0.1, count: OpenAIEmbeddingProvider.defaultDimensions)
        let secondVector = Array(repeating: 0.2, count: OpenAIEmbeddingProvider.defaultDimensions)
        let response = try JSONSerialization.data(withJSONObject: [
            "model": OpenAIEmbeddingProvider.defaultModelID,
            "data": [
                ["index": 1, "embedding": secondVector],
                ["index": 0, "embedding": firstVector],
            ],
        ])
        transport.enqueue(HTTPResponse(status: 200, body: response))

        let vectors = try await provider.embed(
            ["session body", "manual query"],
            instance: instance,
            credentialBinding: CredentialBindingSnapshot(reference: reference, generation: metadata.bindingGeneration),
            credentials: credentials
        )

        #expect(vectors.count == 2)
        #expect(vectors[0].first == 0.1)
        #expect(vectors[1].first == 0.2)
        let request = try #require(transport.lastRequest)
        #expect(request.url.absoluteString == "https://openai.example.test/v1/embeddings")
        #expect(request.headers["Authorization"] == "Bearer embedding-provider-secret")
        #expect(!request.description.contains("embedding-provider-secret"))
        let requestBody = try #require(request.body)
        let json = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        #expect(json["model"] as? String == "text-embedding-3-small")
        #expect(json["dimensions"] as? Int == OpenAIEmbeddingProvider.defaultDimensions)
        #expect(json["encoding_format"] as? String == "float")
        #expect(json["input"] as? [String] == ["session body", "manual query"])
    }
}

private actor SemanticEmbeddingCallRecorder {
    private var recorded: [[String]] = []
    func record(_ inputs: [String]) { recorded.append(inputs) }
    func calls() -> [[String]] { recorded }
    func lastCall() -> [String]? { recorded.last }
}

private struct SemanticTestEmbeddingProvider: EmbeddingProvider {
    let recorder: SemanticEmbeddingCallRecorder
    let providerID = ProviderID.openAI
    let adapterRevision = "semantic-test.v1"
    let modelID = "semantic-test"
    let dimensions = 3

    func embed(_ inputs: [String], instance: ProviderInstance,
                credentialBinding: CredentialBindingSnapshot,
                credentials: any CredentialStoring) async throws -> [[Float]] {
        await recorder.record(inputs)
        return inputs.map { input in
            let value = input.lowercased()
            if value.contains("trip") || value.contains("hiking") || value.contains("mountain")
                || value.contains("compass") || value.contains("alpine") { return [1, 0, 0] }
            if value.contains("bread") || value.contains("bake") { return [0, 1, 0] }
            return [0, 0, 1]
        }
    }
}

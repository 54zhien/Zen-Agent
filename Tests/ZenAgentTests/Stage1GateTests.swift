import Foundation
import Testing

@testable import ZenAgent

@Suite("Stage 1 closure gate")
struct Stage1GateTests {

    private enum GateFixtureError: Error {
        case missingCredentialMetadata
    }

    private let modelID = ModelID(rawValue: "deepseek-flash")
    private let reference = CredentialReference(
        id: "stage1-gate-credential"
    )

    private var instance: ProviderInstance {
        ProviderInstance(
            id: ProviderInstanceID(
                rawValue: "stage1-gate-instance"
            ),
            providerID: .deepSeek,
            displayName: "Stage 1 Gate",
            baseURL: nil,
            configRevision: .initial,
            credentialReference: reference
        )
    }

    private func credentials() throws -> (
        store: CredentialStore,
        binding: CredentialBindingSnapshot
    ) {
        let store = CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository:
                InMemoryCredentialMetadataRepository()
        )

        try store.provision(
            SecretValue("sk-stage1-gate"),
            as: reference
        )

        guard
            let metadata = try store.metadata(
                for: reference
            )
        else {
            throw GateFixtureError.missingCredentialMetadata
        }

        return (
            store,
            CredentialBindingSnapshot(
                reference: reference,
                generation: metadata.bindingGeneration
            )
        )
    }

    private func seed(
        binding: CredentialBindingSnapshot
    ) -> RequestConfigSeed {
        RequestConfigSeed(
            instance: instance,
            modelID: modelID,
            credentialBinding: binding,
            resolvedEndpoint:
                DeepSeekProvider.resolvedEndpoint(
                    for: instance
                )
        )
    }

    private func request() -> ProviderChatRequest {
        PromptComposer().compose(
            PromptCompositionInput(
                modelID: modelID,
                providerAdapterInstructions:
                    "Preserve the provider's plain-text chat semantics.",
                history: [
                    PromptHistoryMessage(
                        role: .user,
                        content: "Earlier user"
                    ),
                    PromptHistoryMessage(
                        role: .assistant,
                        content: "Earlier assistant"
                    ),
                ],
                currentUserMessage: "Current request"
            )
        )
    }

    private func drain(
        provider: any ModelProvider,
        request: ProviderChatRequest,
        seed: RequestConfigSeed,
        credentials: any CredentialStoring
    ) async throws -> [ProviderStreamEvent] {
        let stream = try await provider.stream(
            request,
            seed: seed,
            credentials: credentials
        )

        var events: [ProviderStreamEvent] = []

        for try await event in stream {
            events.append(event)
        }

        return events
    }

    private func visibleText(
        from events: [ProviderStreamEvent]
    ) -> String {
        events
            .compactMap { event -> String? in
                guard case .textDelta(let text) = event else {
                    return nil
                }
                return text
            }
            .joined()
    }

    private func saveConversation(
        at url: URL,
        seed: RequestConfigSeed
    ) throws {
        let store = PersistenceStore(
            database: try ZenDatabase.open(
                at: url.path()
            )
        )

        var commit = Fixtures.send(
            conversationID: "gate-c1",
            messageID: "gate-m1",
            runID: "gate-r1"
        )

        commit.conversation.title = "Stage 1 Gate"

        commit.parts = [
            Fixtures.textPart(
                id: "gate-p1",
                messageID: "gate-m1",
                text: "Current request"
            )
        ]

        commit.run.requestConfigSeed = seed

        try store.commitUserTurnAndCreateParentRun(
            commit
        )
    }

    private func assertConversationRecovered(
        at url: URL,
        expectedSeed: RequestConfigSeed
    ) throws {
        let reopened = PersistenceStore(
            database: try ZenDatabase.open(
                at: url.path()
            )
        )

        #expect(
            try reopened.conversation(
                id: "gate-c1"
            )?.title == "Stage 1 Gate"
        )

        let messages = try reopened.messages(
            inConversation: "gate-c1"
        )

        #expect(messages.map(\.id) == ["gate-m1"])
        #expect(messages.first?.role == .user)

        #expect(
            try reopened.text(
                ofPart: "gate-p1"
            ) == "Current request"
        )

        #expect(
            try reopened.run(
                id: "gate-r1"
            )?.requestConfigSeed == expectedSeed
        )
    }

    @Test(
        "FakeProvider streams stable text and the saved conversation survives restart"
    )
    func fakeProviderPassesStageOneGate() async throws {
        let credentialFixture = try credentials()
        let frozenSeed = seed(
            binding: credentialFixture.binding
        )
        let composed = request()

        let url = try Fixtures.scratchPath(
            name: "stage1-gate-fake.sqlite"
        )
        defer { Fixtures.cleanUp(url) }

        do {
            try saveConversation(
                at: url,
                seed: frozenSeed
            )

            let provider: any ModelProvider = FakeProvider(
                instanceID: instance.id,
                modelNames: [modelID.rawValue],
                scriptedEvents: [
                    .textDelta("Hel"),
                    .textDelta("lo"),
                    .finish(.stop),
                ]
            )

            let events = try await drain(
                provider: provider,
                request: composed,
                seed: frozenSeed,
                credentials: credentialFixture.store
            )

            #expect(
                visibleText(from: events) == "Hello"
            )
            #expect(events.last == .finish(.stop))
        }

        try assertConversationRecovered(
            at: url,
            expectedSeed: frozenSeed
        )
    }

    @Test(
        "DeepSeek adapter streams stable text and the saved conversation survives restart"
    )
    func deepSeekProviderPassesStageOneGate() async throws {
        let credentialFixture = try credentials()
        let frozenSeed = seed(
            binding: credentialFixture.binding
        )
        let composed = request()

        let transport = FakeHTTPTransport()

        // Each frame ends with a blank line, which is where the SSE parser dispatches
        // (SSEParserTests: "a blank line dispatches the event that preceded it"). A
        // multiline literal drops the newline before its closing delimiter, so the blank
        // line above each `"""` is what puts the terminator on the wire.
        transport.enqueueStream([
            """
            data: {"id":"gate","choices":[{"index":0,"delta":{"content":"Hel"}}]}


            """,
            """
            data: {"id":"gate","choices":[{"index":0,"delta":{"content":"lo"},"finish_reason":"stop"}]}


            """,
            """
            data: [DONE]


            """,
        ])

        let provider: any ModelProvider = DeepSeekProvider(
            transport: transport
        )

        let url = try Fixtures.scratchPath(
            name: "stage1-gate-deepseek.sqlite"
        )
        defer { Fixtures.cleanUp(url) }

        do {
            try saveConversation(
                at: url,
                seed: frozenSeed
            )

            let events = try await drain(
                provider: provider,
                request: composed,
                seed: frozenSeed,
                credentials: credentialFixture.store
            )

            #expect(
                visibleText(from: events) == "Hello"
            )
            #expect(events.last == .finish(.stop))
            #expect(transport.requestCount == 1)
        }

        try assertConversationRecovered(
            at: url,
            expectedSeed: frozenSeed
        )
    }
}

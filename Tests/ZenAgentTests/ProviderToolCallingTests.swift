import Foundation
import Testing

@testable import ZenAgent

@Suite("Provider tool calling")
struct ProviderToolCallingTests {

    private let reference = CredentialReference(id: "tool-contract-credential")

    private func fixture() throws -> (
        provider: DeepSeekProvider,
        transport: FakeHTTPTransport,
        seed: RequestConfigSeed,
        credentials: CredentialStore
    ) {
        let credentials = CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: InMemoryCredentialMetadataRepository()
        )
        try credentials.provision(SecretValue("sk-tool-contract"), as: reference)

        let instance = ProviderInstance(
            id: ProviderInstanceID(rawValue: "tool-contract-instance"),
            providerID: .deepSeek,
            displayName: "DeepSeek",
            baseURL: URL(string: "https://api.deepseek.com"),
            configRevision: .initial,
            credentialReference: reference
        )
        let transport = FakeHTTPTransport()
        let provider = DeepSeekProvider(transport: transport)
        let seed = try provider.makeRequestConfigSeed(
            instance: instance,
            modelID: ModelID(rawValue: "deepseek-flash"),
            credentialBinding: CredentialBindingSnapshot(reference: reference, generation: 1)
        )

        return (provider, transport, seed, credentials)
    }

    private func drain(
        _ stream: AsyncThrowingStream<ProviderStreamEvent, Error>
    ) async throws -> [ProviderStreamEvent] {
        var events: [ProviderStreamEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    private func sse(_ payloads: [String]) -> [String] {
        payloads.map { "data: \($0)\n\n" } + ["data: [DONE]\n\n"]
    }

    @Test("DeepSeek advertises the tools capability it can encode")
    func deepSeekAdvertisesTools() throws {
        let f = try fixture()
        let instance = ProviderInstance(
            id: f.seed.providerInstanceID,
            providerID: .deepSeek,
            displayName: "DeepSeek",
            baseURL: URL(string: "https://api.deepseek.com"),
            configRevision: f.seed.providerConfigRevision,
            credentialReference: reference
        )

        let descriptor = try #require(
            f.provider.descriptor(
                for: f.seed.modelID,
                in: instance
            )
        )
        #expect(descriptor.capabilities.contains(.tools))
    }

    @Test("structured tool messages and definitions use the DeepSeek wire contract")
    func encodesStructuredContinuation() async throws {
        let f = try fixture()
        let call = ProviderToolCall(
            id: "call-1",
            index: 0,
            name: "calculator",
            argumentsJSON: #"{"expression":"6*7"}"#
        )
        let definition = ProviderToolDefinition(
            name: "calculator",
            description: "Evaluate an arithmetic expression.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "expression": .object(["type": .string("string")])
                ]),
            ])
        )
        let request = ProviderChatRequest(
            modelID: f.seed.modelID,
            messages: [
                .user("What is 6*7?"),
                .assistant(content: nil, reasoning: "thinking", toolCalls: [call]),
                .toolResult(toolCallID: "call-1", content: "42"),
            ],
            tools: [definition]
        )
        f.transport.enqueue(
            status: 200,
            json: #"{"id":"continuation","choices":[{"message":{"role":"assistant","content":"done"},"finish_reason":"stop"}]}"#
        )

        _ = try await f.provider.complete(
            request,
            seed: f.seed,
            credentials: f.credentials
        )

        let sent = try #require(f.transport.lastRequest)
        let body = try #require(sent.body)
        let object = try JSONSerialization.jsonObject(with: body)
        let json = try #require(object as? [String: Any])
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools.first?["type"] as? String == "function")
        let function = try #require(tools.first?["function"] as? [String: Any])
        #expect(function["name"] as? String == "calculator")

        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages[1]["role"] as? String == "assistant")
        #expect(messages[1]["reasoning_content"] as? String == "thinking")
        let toolCalls = try #require(messages[1]["tool_calls"] as? [[String: Any]])
        #expect(toolCalls.first?["id"] as? String == "call-1")
        #expect(messages[2]["role"] as? String == "tool")
        #expect(messages[2]["tool_call_id"] as? String == "call-1")
    }

    @Test("streamed tool-call fragments assemble by index before finish")
    func assemblesFragmentedToolCalls() async throws {
        let f = try fixture()
        f.transport.enqueueStream(sse([
            #"{"id":"stream-1","choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"call-2","type":"function","function":{"name":"second","arguments":"{\"value\":"}}]}}]}"#,
            #"{"id":"stream-1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call-1","type":"function","function":{"name":"first","arguments":"{\"value\":"}}]}}]}"#,
            #"{"id":"stream-1","choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"function":{"arguments":"2}"}},{"index":0,"function":{"arguments":"1}"}}]}}]}"#,
            #"{"id":"stream-1","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
        ]))

        let events = try await drain(
            try await f.provider.stream(
                ProviderChatRequest(modelID: f.seed.modelID, messages: [.user("calculate")]),
                seed: f.seed,
                credentials: f.credentials
            )
        )

        #expect(events == [
            .toolCall(ProviderToolCall(
                id: "call-1",
                index: 0,
                name: "first",
                argumentsJSON: #"{"value":1}"#
            )),
            .toolCall(ProviderToolCall(
                id: "call-2",
                index: 1,
                name: "second",
                argumentsJSON: #"{"value":2}"#
            )),
            .finish(.toolCalls),
        ])
    }

    @Test("prompt composition carries structured tools without flattening messages")
    func composerCarriesTools() {
        let tool = ProviderToolDefinition(
            name: "current_date",
            description: "Return the current date.",
            parameters: .object(["type": .string("object")])
        )
        let request = PromptComposer().compose(
            PromptCompositionInput(
                modelID: ModelID(rawValue: "deepseek-flash"),
                providerAdapterInstructions: "tool-aware",
                history: [],
                currentUserMessage: "What day is it?",
                tools: [tool]
            )
        )

        #expect(request.tools == [tool])
        guard let firstMessage = request.messages.first else {
            Issue.record("expected the composer to create a system message")
            return
        }
        guard case .system(let systemMessage) = firstMessage else {
            Issue.record("expected the first message to be structured as system")
            return
        }
        #expect(systemMessage.contains("tool-aware"))
        #expect(request.messages.last == .user("What day is it?"))
    }
}

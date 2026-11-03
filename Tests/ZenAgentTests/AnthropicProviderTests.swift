import Foundation
import Testing

@testable import ZenAgent

@Suite("Anthropic Messages provider")
struct AnthropicProviderTests {
    private struct Fixture {
        let provider: AnthropicProvider
        let transport: FakeHTTPTransport
        let instance: ProviderInstance
        let credentials: CredentialStore
        let seed: RequestConfigSeed
    }

    private func makeFixture(baseURL: URL? = nil) throws -> Fixture {
        let transport = FakeHTTPTransport()
        let provider = AnthropicProvider(transport: transport)
        let reference = CredentialReference(id: "anthropic-provider-test-key")
        let credentials = CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: InMemoryCredentialMetadataRepository()
        )
        try credentials.provision(SecretValue("anthropic-test-key"), as: reference)
        let metadata = try #require(try credentials.metadata(for: reference))
        let instance = ProviderInstance(
            id: ProviderInstanceID(rawValue: "anthropic-provider-test-account"),
            providerID: .anthropic,
            displayName: "Anthropic",
            baseURL: baseURL,
            configRevision: .initial,
            credentialReference: reference
        )
        let seed = try provider.makeRequestConfigSeed(
            instance: instance,
            modelID: AnthropicProvider.defaultModelID,
            credentialBinding: CredentialBindingSnapshot(
                reference: metadata.reference,
                generation: metadata.bindingGeneration
            )
        )
        return Fixture(
            provider: provider,
            transport: transport,
            instance: instance,
            credentials: credentials,
            seed: seed
        )
    }

    private func drain(
        _ stream: AsyncThrowingStream<ProviderStreamEvent, Error>
    ) async throws -> [ProviderStreamEvent] {
        var events: [ProviderStreamEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    @Test("the catalog exposes the frozen Sonnet text, streaming, and tool contract")
    func modelCapabilitiesAreAdapterOwned() throws {
        let fixture = try makeFixture()
        let descriptor = try #require(fixture.provider.descriptor(
            for: AnthropicProvider.defaultModelID,
            in: fixture.instance
        ))

        #expect(descriptor.id.rawValue == "claude-sonnet-5")
        #expect(descriptor.capabilities == [.text, .streaming, .tools])
        #expect(descriptor.thinkingEfforts == nil)
        #expect(descriptor.defaultThinkingEffort == nil)
        #expect(fixture.seed.maxOutputTokens == 4096)
        #expect(fixture.seed.formatVersion == 3)
        #expect(fixture.provider.descriptor(
            for: ModelID(rawValue: "unknown-anthropic-model"),
            in: fixture.instance
        ) == nil)
    }

    @Test("request freezes Messages endpoint, output limit, thinking mode, and structured tool history")
    func requestUsesAnthropicMessagesWireShape() async throws {
        let fixture = try makeFixture()
        fixture.transport.enqueueStream([
            "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n",
            "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n",
            "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
        ])
        let request = ProviderChatRequest(
            modelID: AnthropicProvider.defaultModelID,
            messages: [
                .system("Follow the frozen system prompt."),
                .user("Run both tools."),
                .assistant(
                    content: "I will check both.",
                    reasoning: nil,
                    toolCalls: [
                        ProviderToolCall(
                            id: "tool_weather",
                            index: 0,
                            name: "get_weather",
                            argumentsJSON: "{\"city\":\"Paris\"}"
                        ),
                        ProviderToolCall(
                            id: "tool_clock",
                            index: 1,
                            name: "get_time",
                            argumentsJSON: "{}"
                        ),
                    ]
                ),
                .toolResult(toolCallID: "tool_weather", content: "{\"degrees\":18}"),
                .toolResult(toolCallID: "tool_clock", content: "noon"),
            ],
            tools: [
                ProviderToolDefinition(
                    name: "get_weather",
                    description: "Read weather.",
                    parameters: .object(["type": .string("object")])
                ),
                ProviderToolDefinition(
                    name: "get_time",
                    description: "Read time.",
                    parameters: .object(["type": .string("object")])
                ),
            ]
        )

        _ = try await drain(try await fixture.provider.stream(
            request,
            seed: fixture.seed,
            credentials: fixture.credentials
        ))

        let sent = try #require(fixture.transport.lastRequest)
        #expect(sent.method == .post)
        #expect(sent.url.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(sent.headers["Authorization"] == "Bearer anthropic-test-key")
        #expect(sent.headers["anthropic-version"] == "2026-10-21")
        #expect(sent.headers["Accept"] == "text/event-stream")
        #expect(sent.description.contains("anthropic-test-key") == false)

        let body = try #require(sent.body)
        let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(root["model"] as? String == "claude-sonnet-5")
        #expect(root["max_tokens"] as? Int == 4096)
        #expect(root["stream"] as? Bool == true)
        let thinking = try #require(root["thinking"] as? [String: Any])
        #expect(thinking["type"] as? String == "disabled")

        let system = try #require(root["system"] as? [[String: Any]])
        #expect(system.count == 1)
        #expect(system[0]["text"] as? String == "Follow the frozen system prompt.")

        let messages = try #require(root["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["user", "assistant", "user"])
        let assistantBlocks = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(assistantBlocks.first?["type"] as? String == "text")
        #expect(assistantBlocks.filter { $0["type"] as? String == "tool_use" }.map {
            $0["id"] as? String
        } == ["tool_weather", "tool_clock"])
        let resultBlocks = try #require(messages[2]["content"] as? [[String: Any]])
        #expect(resultBlocks.map { $0["tool_use_id"] as? String } == ["tool_weather", "tool_clock"])
        let tools = try #require(root["tools"] as? [[String: Any]])
        #expect(tools.map { $0["name"] as? String } == ["get_weather", "get_time"])
        #expect(tools.allSatisfy { $0["input_schema"] is [String: Any] })
    }

    @Test("the Messages endpoint is resolved from a custom provider base URL")
    func customEndpointIsFrozen() throws {
        let fixture = try makeFixture(baseURL: URL(string: "https://anthropic.example.test/v1"))
        #expect(fixture.seed.endpoint.absoluteString == "https://anthropic.example.test/v1/messages")
    }
}

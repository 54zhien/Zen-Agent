import Foundation
import Testing

@testable import ZenAgent

@Suite("GLM Chat Completions provider")
struct GLMProviderTests {
    private struct Fixture {
        let provider: GLMProvider
        let transport: FakeHTTPTransport
        let instance: ProviderInstance
        let credentials: CredentialStore
        let seed: RequestConfigSeed
    }

    private func makeFixture(
        baseURL: URL? = nil,
        thinkingEffort: ThinkingEffort? = nil
    ) throws -> Fixture {
        let transport = FakeHTTPTransport()
        let provider = GLMProvider(transport: transport)
        let reference = CredentialReference(id: "glm-provider-test-key")
        let credentials = CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: InMemoryCredentialMetadataRepository()
        )
        try credentials.provision(SecretValue("glm-test-key"), as: reference)
        let metadata = try #require(try credentials.metadata(for: reference))
        let instance = ProviderInstance(
            id: ProviderInstanceID(rawValue: "glm-provider-instance"),
            providerID: .glm,
            displayName: "GLM",
            baseURL: baseURL,
            configRevision: .initial,
            credentialReference: reference
        )
        let seed = try provider.makeRequestConfigSeed(
            instance: instance,
            modelID: GLMProvider.defaultModelID,
            credentialBinding: CredentialBindingSnapshot(
                reference: metadata.reference,
                generation: metadata.bindingGeneration
            ),
            thinkingEffort: thinkingEffort
        )
        return Fixture(
            provider: provider,
            transport: transport,
            instance: instance,
            credentials: credentials,
            seed: seed
        )
    }

    @Test("catalog reflects the documented GLM-5.3 text and reasoning capabilities")
    func catalogUsesDocumentedModelCapabilities() throws {
        let fixture = try makeFixture()
        let descriptor = try #require(fixture.provider.descriptor(
            for: GLMProvider.defaultModelID,
            in: fixture.instance
        ))

        #expect(descriptor.id.rawValue == "glm-5.3")
        #expect(descriptor.capabilities == [.text, .streaming, .reasoning, .tools])
        #expect(descriptor.thinkingEfforts == [.low, .high, .max])
        #expect(descriptor.defaultThinkingEffort == nil)
    }

    @Test("request translates messages and function tools to GLM Chat Completions")
    func requestUsesGLMChatCompletionShape() async throws {
        let fixture = try makeFixture()
        fixture.transport.enqueueStream(["data: [DONE]\n\n"])
        let request = ProviderChatRequest(
            modelID: GLMProvider.defaultModelID,
            messages: [
                .system("Follow the frozen prompt."),
                .user("Check the weather."),
                .assistant(
                    content: nil,
                    reasoning: "The user asked for current conditions.",
                    toolCalls: [
                        ProviderToolCall(
                            id: "call_weather",
                            index: 0,
                            name: "get_weather",
                            argumentsJSON: "{\"city\":\"Oslo\"}"
                        ),
                    ]
                ),
                .toolResult(toolCallID: "call_weather", content: "{\"degrees\":8}"),
            ],
            tools: [
                ProviderToolDefinition(
                    name: "get_weather",
                    description: "Read current weather.",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object(["city": .object(["type": .string("string")])]),
                    ])
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
        #expect(sent.url.absoluteString == "https://open.bigmodel.cn/api/paas/v4/chat/completions")
        #expect(sent.headers["Authorization"] == "Bearer glm-test-key")
        #expect(sent.headers["Accept"] == "text/event-stream")
        #expect(sent.description.contains("glm-test-key") == false)

        let body = try #require(sent.body)
        let root = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(root["model"] as? String == "glm-5.3")
        #expect(root["stream"] as? Bool == true)
        #expect(root["tool_stream"] as? Bool == true)
        #expect(root["max_tokens"] == nil)
        #expect(root["reasoning_effort"] == nil)
        #expect((root["thinking"] as? [String: Any])?["type"] as? String == "enabled")

        let messages = try #require(root["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user", "assistant", "tool"])
        #expect(messages[2]["content"] is NSNull)
        #expect(messages[2]["reasoning_content"] as? String == "The user asked for current conditions.")
        #expect(messages[2]["tool_calls"] != nil)
        #expect(messages[3]["tool_call_id"] as? String == "call_weather")

        let tools = try #require(root["tools"] as? [[String: Any]])
        #expect(tools.first?["type"] as? String == "function")
        #expect((tools.first?["function"] as? [String: Any])?["name"] as? String == "get_weather")
    }

    @Test("only the frozen effort override is sent")
    func requestUsesFrozenThinkingEffort() async throws {
        let fixture = try makeFixture(thinkingEffort: .low)
        fixture.transport.enqueueStream(["data: [DONE]\n\n"])
        _ = try await drain(try await fixture.provider.stream(
            ProviderChatRequest(modelID: GLMProvider.defaultModelID, messages: [.user("Hi")]),
            seed: fixture.seed,
            credentials: fixture.credentials
        ))

        let body = try #require(fixture.transport.lastRequest?.body)
        let root = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(root["reasoning_effort"] as? String == "low")
        #expect(root["max_tokens"] == nil)
    }

    @Test("custom base URL is frozen with the chat completions path")
    func endpointUsesConfiguredBaseURL() throws {
        let fixture = try makeFixture(baseURL: URL(string: "https://glm.example.test/api/paas/v4"))
        #expect(fixture.seed.endpoint.absoluteString == "https://glm.example.test/api/paas/v4/chat/completions")
    }

    private func drain(
        _ stream: AsyncThrowingStream<ProviderStreamEvent, Error>
    ) async throws -> [ProviderStreamEvent] {
        var events: [ProviderStreamEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }
}
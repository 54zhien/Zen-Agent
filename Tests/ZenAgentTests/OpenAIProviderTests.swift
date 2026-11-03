import Foundation
import Testing

@testable import ZenAgent

@Suite("OpenAI Responses provider")
struct OpenAIProviderTests {
    private struct Fixture {
        let provider: OpenAIProvider
        let transport: FakeHTTPTransport
        let instance: ProviderInstance
        let credentials: CredentialStore
        let seed: RequestConfigSeed
    }

    private func makeFixture(baseURL: URL? = nil) throws -> Fixture {
        let transport = FakeHTTPTransport()
        let provider = OpenAIProvider(transport: transport)
        let reference = CredentialReference(id: "openai-provider-test-key")
        let credentials = CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: InMemoryCredentialMetadataRepository()
        )
        try credentials.provision(SecretValue("openai-test-key"), as: reference)
        let metadata = try #require(try credentials.metadata(for: reference))
        let instance = ProviderInstance(
            id: ProviderInstanceID(rawValue: "openai-provider-test-account"),
            providerID: .openAI,
            displayName: "OpenAI",
            baseURL: baseURL,
            configRevision: .initial,
            credentialReference: reference
        )
        let seed = try provider.makeRequestConfigSeed(
            instance: instance,
            modelID: OpenAIProvider.defaultModelID,
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

    @Test("catalog exposes only the documented text streaming and tool capabilities")
    func modelCapabilitiesAreAdapterOwned() throws {
        let fixture = try makeFixture()
        let descriptor = try #require(fixture.provider.descriptor(
            for: OpenAIProvider.defaultModelID,
            in: fixture.instance
        ))

        #expect(descriptor.id.rawValue == "gpt-6.1-terra")
        #expect(descriptor.capabilities == [.text, .streaming, .tools])
        #expect(descriptor.thinkingEfforts == nil)
        #expect(descriptor.defaultThinkingEffort == nil)
        #expect(fixture.provider.descriptor(
            for: ModelID(rawValue: "unknown-openai-model"),
            in: fixture.instance
        ) == nil)
    }

    @Test("the Responses endpoint is frozen from the provider base URL")
    func responseEndpointIsFrozen() throws {
        let defaultFixture = try makeFixture()
        #expect(defaultFixture.seed.endpoint.absoluteString == "https://api.openai.com/v1/responses")

        let customFixture = try makeFixture(baseURL: URL(string: "https://openai.example.test/v1"))
        #expect(customFixture.seed.endpoint.absoluteString == "https://openai.example.test/v1/responses")
    }

    @Test("request maps provider neutral history and multiple tools to Responses input")
    func requestUsesResponsesWireShape() async throws {
        let fixture = try makeFixture()
        fixture.transport.enqueueStream([
            "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"status\":\"completed\",\"output\":[]}}\n\n"
        ])
        let request = ProviderChatRequest(
            modelID: OpenAIProvider.defaultModelID,
            messages: [
                .system("Follow the frozen system prompt."),
                .user("Run both tools."),
                .assistant(
                    content: nil,
                    reasoning: nil,
                    toolCalls: [
                        ProviderToolCall(
                            id: "call_weather",
                            index: 0,
                            name: "get_weather",
                            argumentsJSON: "{\"city\":\"Paris\"}"
                        ),
                        ProviderToolCall(
                            id: "call_clock",
                            index: 1,
                            name: "get_time",
                            argumentsJSON: "{}"
                        ),
                    ]
                ),
                .toolResult(toolCallID: "call_weather", content: "{\"degrees\":18}"),
                .toolResult(toolCallID: "call_clock", content: "noon"),
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

        _ = try await fixture.provider.stream(
            request,
            seed: fixture.seed,
            credentials: fixture.credentials
        )

        let sent = try #require(fixture.transport.lastRequest)
        #expect(sent.method == .post)
        #expect(sent.url == fixture.seed.endpoint)
        #expect(sent.headers["Authorization"] == "Bearer openai-test-key")
        #expect(sent.headers["Accept"] == "text/event-stream")
        #expect(sent.description.contains("openai-test-key") == false)
        let body = try #require(sent.body)
        let root = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(root["model"] as? String == "gpt-6.1-terra")
        #expect(root["stream"] as? Bool == true)
        #expect(root["store"] as? Bool == false)
        let reasoning = try #require(root["reasoning"] as? [String: Any])
        #expect(reasoning["effort"] as? String == "none")

        let input = try #require(root["input"] as? [[String: Any]])
        #expect(input.contains { $0["role"] as? String == "system" })
        #expect(input.contains { $0["type"] as? String == "function_call" && $0["call_id"] as? String == "call_weather" })
        #expect(input.contains { $0["type"] as? String == "function_call" && $0["call_id"] as? String == "call_clock" })
        #expect(input.contains { $0["type"] as? String == "function_call_output" && $0["call_id"] as? String == "call_weather" })
        #expect(input.contains { $0["type"] as? String == "function_call_output" && $0["call_id"] as? String == "call_clock" })

        let tools = try #require(root["tools"] as? [[String: Any]])
        #expect(tools.map { $0["name"] as? String } == ["get_weather", "get_time"])
        #expect(tools.allSatisfy { $0["type"] as? String == "function" })
    }

    @Test("a refused credential maps to the existing provider error")
    func unauthorizedResponseUsesProviderError() async throws {
        let fixture = try makeFixture()
        fixture.transport.failStream(with: .httpStatus(HTTPResponse(
            status: 401,
            json: "{\"error\":{\"message\":\"invalid key\"}}"
        )))
        let request = ProviderChatRequest(
            modelID: OpenAIProvider.defaultModelID,
            messages: [.user("Hello")]
        )

        var failure: Error?
        do {
            _ = try await fixture.provider.stream(
                request,
                seed: fixture.seed,
                credentials: fixture.credentials
            )
        } catch {
            failure = error
        }

        #expect(failure as? ProviderError == .credentialRejectedByHTTP401)
        #expect(fixture.transport.requestCount == 1)
    }
}

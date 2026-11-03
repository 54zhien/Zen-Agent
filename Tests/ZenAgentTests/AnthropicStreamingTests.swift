import Foundation
import Testing

@testable import ZenAgent

@Suite("Anthropic Messages streaming")
struct AnthropicStreamingTests {
    private struct Fixture {
        let provider: AnthropicProvider
        let transport: FakeHTTPTransport
        let credentials: CredentialStore
        let seed: RequestConfigSeed
    }

    private func makeFixture() throws -> Fixture {
        let transport = FakeHTTPTransport()
        let provider = AnthropicProvider(transport: transport)
        let reference = CredentialReference(id: "anthropic-stream-test-key")
        let credentials = CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: InMemoryCredentialMetadataRepository()
        )
        try credentials.provision(SecretValue("anthropic-stream-key"), as: reference)
        let metadata = try #require(try credentials.metadata(for: reference))
        let instance = ProviderInstance(
            id: ProviderInstanceID(rawValue: "anthropic-stream-account"),
            providerID: .anthropic,
            displayName: "Anthropic",
            baseURL: nil,
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
        return Fixture(provider: provider, transport: transport, credentials: credentials, seed: seed)
    }

    private func request() -> ProviderChatRequest {
        ProviderChatRequest(
            modelID: AnthropicProvider.defaultModelID,
            messages: [.user("Answer and use tools where needed.")]
        )
    }

    private func frame(_ type: String, _ payload: [String: Any]) throws -> String {
        let json = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return "event: \(type)\ndata: \(String(decoding: json, as: UTF8.self))\n\n"
    }

    private func drain(
        _ stream: AsyncThrowingStream<ProviderStreamEvent, Error>
    ) async throws -> [ProviderStreamEvent] {
        var events: [ProviderStreamEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    @Test("text deltas and cumulative usage end at message_stop")
    func textAndTerminalMessage() async throws {
        let fixture = try makeFixture()
        fixture.transport.enqueueStream([
            try frame("message_start", [
                "type": "message_start",
                "message": ["usage": ["input_tokens": 5, "output_tokens": 1]],
            ]),
            try frame("content_block_start", [
                "type": "content_block_start",
                "index": 0,
                "content_block": ["type": "text", "text": ""],
            ]),
            try frame("ping", ["type": "ping"]),
            try frame("content_block_delta", [
                "type": "content_block_delta",
                "index": 0,
                "delta": ["type": "text_delta", "text": "Hello"],
            ]),
            try frame("content_block_delta", [
                "type": "content_block_delta",
                "index": 0,
                "delta": ["type": "text_delta", "text": " world"],
            ]),
            try frame("content_block_stop", ["type": "content_block_stop", "index": 0]),
            try frame("message_delta", [
                "type": "message_delta",
                "delta": ["stop_reason": "end_turn", "stop_sequence": NSNull()],
                "usage": ["output_tokens": 2],
            ]),
            try frame("message_stop", ["type": "message_stop"]),
        ])

        let events = try await drain(try await fixture.provider.stream(
            request(), seed: fixture.seed, credentials: fixture.credentials
        ))

        #expect(events == [
            .textDelta("Hello"),
            .textDelta(" world"),
            .usage(ProviderTokenUsage(promptTokens: 5, completionTokens: 2, totalTokens: 7)),
            .finish(.stop),
        ])
    }

    @Test("tool JSON deltas are assembled at content_block_stop with their block indexes")
    func parallelToolCallsKeepTheirIDsAndIndexes() async throws {
        let fixture = try makeFixture()
        fixture.transport.enqueueStream([
            try frame("message_start", [
                "type": "message_start",
                "message": ["usage": ["input_tokens": 4, "output_tokens": 1]],
            ]),
            try frame("content_block_start", [
                "type": "content_block_start",
                "index": 0,
                "content_block": ["type": "tool_use", "id": "tool_weather", "name": "get_weather", "input": [:]],
            ]),
            try frame("content_block_start", [
                "type": "content_block_start",
                "index": 1,
                "content_block": ["type": "tool_use", "id": "tool_clock", "name": "get_time", "input": [:]],
            ]),
            try frame("content_block_delta", [
                "type": "content_block_delta",
                "index": 1,
                "delta": ["type": "input_json_delta", "partial_json": "{}"],
            ]),
            try frame("content_block_stop", ["type": "content_block_stop", "index": 1]),
            try frame("content_block_delta", [
                "type": "content_block_delta",
                "index": 0,
                "delta": ["type": "input_json_delta", "partial_json": "{\"city\":"],
            ]),
            try frame("content_block_delta", [
                "type": "content_block_delta",
                "index": 0,
                "delta": ["type": "input_json_delta", "partial_json": "\"Paris\"}"],
            ]),
            try frame("content_block_stop", ["type": "content_block_stop", "index": 0]),
            try frame("message_delta", [
                "type": "message_delta",
                "delta": ["stop_reason": "tool_use"],
                "usage": ["output_tokens": 3],
            ]),
            try frame("message_stop", ["type": "message_stop"]),
        ])

        let events = try await drain(try await fixture.provider.stream(
            request(), seed: fixture.seed, credentials: fixture.credentials
        ))

        #expect(events == [
            .toolCall(ProviderToolCall(id: "tool_clock", index: 1, name: "get_time", argumentsJSON: "{}")),
            .toolCall(ProviderToolCall(
                id: "tool_weather", index: 0, name: "get_weather", argumentsJSON: "{\"city\":\"Paris\"}"
            )),
            .usage(ProviderTokenUsage(promptTokens: 4, completionTokens: 3, totalTokens: 7)),
            .finish(.toolCalls),
        ])
    }

    @Test("a normally closed SSE body without message_stop remains interrupted after text")
    func missingMessageStopIsInterrupted() async throws {
        let fixture = try makeFixture()
        fixture.transport.enqueueStream([
            try frame("message_start", [
                "type": "message_start",
                "message": ["usage": ["input_tokens": 3, "output_tokens": 1]],
            ]),
            try frame("content_block_start", [
                "type": "content_block_start",
                "index": 0,
                "content_block": ["type": "text", "text": ""],
            ]),
            try frame("content_block_delta", [
                "type": "content_block_delta",
                "index": 0,
                "delta": ["type": "text_delta", "text": "partial"],
            ]),
        ])

        var failure: Error?
        do {
            _ = try await drain(try await fixture.provider.stream(
                request(), seed: fixture.seed, credentials: fixture.credentials
            ))
        } catch {
            failure = error
        }

        guard let providerError = failure as? ProviderError,
              case .streamInterrupted(let deliveredOutput, _) = providerError else {
            Issue.record("Expected a stream interruption after a nonterminal Anthropic message.")
            return
        }
        #expect(deliveredOutput)
        #expect(providerError.retryDisposition == .doNotRetry)
        #expect(fixture.transport.requestCount == 1)
    }
}

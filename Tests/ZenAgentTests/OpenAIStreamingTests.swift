import Foundation
import Testing

@testable import ZenAgent

@Suite("OpenAI Responses streaming")
struct OpenAIStreamingTests {
    private struct Fixture {
        let provider: OpenAIProvider
        let transport: FakeHTTPTransport
        let credentials: CredentialStore
        let seed: RequestConfigSeed
    }

    private func makeFixture() throws -> Fixture {
        let transport = FakeHTTPTransport()
        let provider = OpenAIProvider(transport: transport)
        let reference = CredentialReference(id: "openai-stream-test-key")
        let credentials = CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: InMemoryCredentialMetadataRepository()
        )
        try credentials.provision(SecretValue("openai-stream-key"), as: reference)
        let metadata = try #require(try credentials.metadata(for: reference))
        let instance = ProviderInstance(
            id: ProviderInstanceID(rawValue: "openai-stream-account"),
            providerID: .openAI,
            displayName: "OpenAI",
            baseURL: nil,
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
            credentials: credentials,
            seed: seed
        )
    }

    private func request() -> ProviderChatRequest {
        ProviderChatRequest(
            modelID: OpenAIProvider.defaultModelID,
            messages: [.user("Run the tools and summarize.")]
        )
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

    @Test("semantic text and completion usage normalize to ordered provider events")
    func textAndCompletedResponse() async throws {
        let fixture = try makeFixture()
        fixture.transport.enqueueStream([
            "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"content_index\":0,\"delta\":\"Hello\"}\n\n",
            "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"content_index\":0,\"delta\":\" world\"}\n\n",
            "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_text\",\"status\":\"completed\",\"usage\":{\"input_tokens\":5,\"output_tokens\":2,\"total_tokens\":7},\"output\":[]}}\n\n",
        ])

        let events = try await drain(try await fixture.provider.stream(
            request(),
            seed: fixture.seed,
            credentials: fixture.credentials
        ))

        #expect(events == [
            .textDelta("Hello"),
            .textDelta(" world"),
            .usage(ProviderTokenUsage(promptTokens: 5, completionTokens: 2, totalTokens: 7)),
            .finish(.stop),
        ])
    }

    @Test("parallel function calls keep their call IDs and output indexes until arguments are complete")
    func multipleFunctionCallsCompleteAtTheirIndexes() async throws {
        let fixture = try makeFixture()
        fixture.transport.enqueueStream([
            "event: response.output_item.added\ndata: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"fc_item_weather\",\"call_id\":\"call_weather\",\"name\":\"get_weather\",\"arguments\":\"\"}}\n\n",
            "event: response.function_call_arguments.delta\ndata: {\"type\":\"response.function_call_arguments.delta\",\"item_id\":\"fc_item_weather\",\"output_index\":0,\"delta\":\"{\\\"city\\\":\"}\n\n",
            "event: response.output_item.added\ndata: {\"type\":\"response.output_item.added\",\"output_index\":1,\"item\":{\"type\":\"function_call\",\"id\":\"fc_item_clock\",\"call_id\":\"call_clock\",\"name\":\"get_time\",\"arguments\":\"\"}}\n\n",
            "event: response.function_call_arguments.delta\ndata: {\"type\":\"response.function_call_arguments.delta\",\"item_id\":\"fc_item_clock\",\"output_index\":1,\"delta\":\"{}\"}\n\n",
            "event: response.function_call_arguments.done\ndata: {\"type\":\"response.function_call_arguments.done\",\"item_id\":\"fc_item_clock\",\"output_index\":1,\"arguments\":\"{}\"}\n\n",
            "event: response.function_call_arguments.delta\ndata: {\"type\":\"response.function_call_arguments.delta\",\"item_id\":\"fc_item_weather\",\"output_index\":0,\"delta\":\"Paris\\\"}\"}\n\n",
            "event: response.function_call_arguments.done\ndata: {\"type\":\"response.function_call_arguments.done\",\"item_id\":\"fc_item_weather\",\"output_index\":0,\"arguments\":\"{\\\"city\\\":\\\"Paris\\\"}\"}\n\n",
            "event: response.output_item.done\ndata: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"fc_item_weather\",\"call_id\":\"call_weather\",\"name\":\"get_weather\",\"arguments\":\"{\\\"city\\\":\\\"Paris\\\"}\"}}\n\n",
            "event: response.output_item.done\ndata: {\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":{\"type\":\"function_call\",\"id\":\"fc_item_clock\",\"call_id\":\"call_clock\",\"name\":\"get_time\",\"arguments\":\"{}\"}}\n\n",
            "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_tools\",\"status\":\"completed\",\"output\":[]}}\n\n",
        ])

        let events = try await drain(try await fixture.provider.stream(
            request(),
            seed: fixture.seed,
            credentials: fixture.credentials
        ))
        let calls = events.compactMap { event -> ProviderToolCall? in
            guard case .toolCall(let call) = event else { return nil }
            return call
        }

        #expect(calls == [
            ProviderToolCall(id: "call_clock", index: 1, name: "get_time", argumentsJSON: "{}"),
            ProviderToolCall(
                id: "call_weather",
                index: 0,
                name: "get_weather",
                argumentsJSON: "{\"city\":\"Paris\"}"
            ),
        ])
        #expect(events.last == .finish(.toolCalls))
    }

    @Test("a normally closed SSE stream without a terminal response is interrupted after delivered text")
    func missingSemanticTerminalIsInterrupted() async throws {
        let fixture = try makeFixture()
        fixture.transport.enqueueStream([
            "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"content_index\":0,\"delta\":\"partial\"}\n\n",
        ])

        var failure: Error?
        do {
            _ = try await drain(try await fixture.provider.stream(
                request(),
                seed: fixture.seed,
                credentials: fixture.credentials
            ))
        } catch {
            failure = error
        }

        guard let providerError = failure as? ProviderError,
              case .streamInterrupted(let deliveredOutput, _) = providerError
        else {
            Issue.record("Expected a stream interruption after the nonterminal response.")
            return
        }
        #expect(deliveredOutput)
        #expect(fixture.transport.requestCount == 1)
    }

    @Test("a failed response after delivered text is never replayable")
    func failedResponseAfterTextCannotBeReplayed() async throws {
        let fixture = try makeFixture()
        fixture.transport.enqueueStream([
            "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n",
            "event: response.failed\ndata: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"server_error\",\"message\":\"request failed\"}}}\n\n",
        ])

        var failure: Error?
        do {
            _ = try await drain(try await fixture.provider.stream(
                request(),
                seed: fixture.seed,
                credentials: fixture.credentials
            ))
        } catch {
            failure = error
        }

        guard let providerError = failure as? ProviderError,
              case .streamInterrupted(let deliveredOutput, _) = providerError else {
            Issue.record("Expected a failed response after delivered text to interrupt the stream.")
            return
        }
        #expect(deliveredOutput)
        #expect(providerError.retryDisposition == .doNotRetry)
        #expect(fixture.transport.requestCount == 1)
    }

    @Test("a top-level Responses error event keeps its rate limit classification")
    func topLevelErrorKeepsRateLimitClassification() async throws {
        let fixture = try makeFixture()
        fixture.transport.enqueueStream([
            "event: error\ndata: {\"type\":\"error\",\"code\":\"rate_limit_exceeded\",\"message\":\"try later\"}\n\n",
        ])

        var failure: Error?
        do {
            _ = try await drain(try await fixture.provider.stream(
                request(),
                seed: fixture.seed,
                credentials: fixture.credentials
            ))
        } catch {
            failure = error
        }

        #expect(failure as? ProviderError == .rateLimited(retryAfter: nil))
        #expect(fixture.transport.requestCount == 1)
    }

    @Test("consumer cancellation reaches the HTTP stream")
    func consumerCancellationCancelsTransport() async throws {
        let fixture = try makeFixture()
        fixture.transport.stallStream(after: [])
        let stream = try await fixture.provider.stream(
            request(),
            seed: fixture.seed,
            credentials: fixture.credentials
        )
        let consumer = Task {
            for try await _ in stream { }
        }

        consumer.cancel()
        _ = try? await consumer.value

        #expect(fixture.transport.streamCancellations == 1)
        #expect(fixture.transport.requestCount == 1)
    }
}

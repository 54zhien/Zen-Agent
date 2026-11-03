import Foundation
import Testing

@testable import ZenAgent

@Suite("GLM streaming")
struct GLMStreamingTests {
    private struct Fixture {
        let provider: GLMProvider
        let transport: FakeHTTPTransport
        let credentials: CredentialStore
        let seed: RequestConfigSeed
    }

    private func makeFixture() throws -> Fixture {
        let transport = FakeHTTPTransport()
        let provider = GLMProvider(transport: transport)
        let reference = CredentialReference(id: "glm-stream-test-key")
        let credentials = CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: InMemoryCredentialMetadataRepository()
        )
        try credentials.provision(SecretValue("glm-stream-secret"), as: reference)
        let metadata = try #require(try credentials.metadata(for: reference))
        let instance = ProviderInstance(
            id: ProviderInstanceID(rawValue: "glm-stream-instance"),
            providerID: .glm,
            displayName: "GLM",
            baseURL: nil,
            configRevision: .initial,
            credentialReference: reference
        )
        return Fixture(
            provider: provider,
            transport: transport,
            credentials: credentials,
            seed: try provider.makeRequestConfigSeed(
                instance: instance,
                modelID: GLMProvider.defaultModelID,
                credentialBinding: CredentialBindingSnapshot(
                    reference: metadata.reference,
                    generation: metadata.bindingGeneration
                )
            )
        )
    }

    @Test("reasoning, answer, fragmented tool arguments, usage, and finish retain protocol order")
    func streamReassemblesGLMEvents() async throws {
        let fixture = try makeFixture()
        fixture.transport.enqueueStream([
            #"data: {"id":"glm-1","choices":[{"index":0,"delta":{"reasoning_content":"Check the forecast."}}]}"# + "\n\n",
            #"data: {"id":"glm-1","choices":[{"index":0,"delta":{"content":"Rain"}}]}"# + "\n\n",
            #"data: {"id":"glm-1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_weather","type":"function","function":{"name":"get_weather","arguments":"{\"city\":"}}]}}]}"# + "\n\n",
            #"data: {"id":"glm-1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"Oslo\"}"}}]}}]}"# + "\n\n",
            #"data: {"id":"glm-1","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":7,"completion_tokens":4,"total_tokens":11}}"# + "\n\n",
            "data: [DONE]\n\n",
        ])

        let events = try await drain(try await fixture.provider.stream(
            ProviderChatRequest(modelID: GLMProvider.defaultModelID, messages: [.user("Weather?")]),
            seed: fixture.seed,
            credentials: fixture.credentials
        ))

        #expect(events == [
            .reasoningDelta("Check the forecast."),
            .textDelta("Rain"),
            .toolCall(ProviderToolCall(
                id: "call_weather",
                index: 0,
                name: "get_weather",
                argumentsJSON: "{\"city\":\"Oslo\"}"
            )),
            .usage(ProviderTokenUsage(promptTokens: 7, completionTokens: 4, totalTokens: 11)),
            .finish(.toolCalls),
        ])
    }

    @Test("a stream without the GLM terminator is reported as interrupted")
    func missingTerminatorIsInterrupted() async throws {
        let fixture = try makeFixture()
        fixture.transport.enqueueStream([
            #"data: {"id":"glm-2","choices":[{"index":0,"delta":{"content":"partial"}}]}"# + "\n\n",
        ])

        var failure: ProviderError?
        do {
            _ = try await drain(try await fixture.provider.stream(
                ProviderChatRequest(modelID: GLMProvider.defaultModelID, messages: [.user("Hi")]),
                seed: fixture.seed,
                credentials: fixture.credentials
            ))
        } catch let error as ProviderError {
            failure = error
        }

        guard case .streamInterrupted(let deliveredOutput, _) = failure else {
            Issue.record("expected an interrupted GLM stream, got \(String(describing: failure))")
            return
        }
        #expect(deliveredOutput)
    }

    private func drain(
        _ stream: AsyncThrowingStream<ProviderStreamEvent, Error>
    ) async throws -> [ProviderStreamEvent] {
        var events: [ProviderStreamEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }
}
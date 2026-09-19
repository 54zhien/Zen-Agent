import Foundation
import Testing

@testable import ZenAgent

/// Product invariant: **a streamed completion is reassembled into the same content a
/// non-streamed one would have produced, and every way it can stop is described
/// honestly.**
///
/// The wire behaviour asserted here is DeepSeek's current documented behaviour, not an
/// assumption about it: `reasoning_content` and `content` both arrive as deltas, the
/// final chunk before `[DONE]` carries the usage, and that final chunk still holds
/// exactly one choice which may have a `finish_reason` and no content at all.
///
/// That last shape is why "a chunk with no text" must not be an error. A decoder that
/// treated it as malformed would fail on every stream at the exact moment the stream
/// succeeded, and the failure would be at the end, where it costs the whole answer.
@Suite("DeepSeek streaming")
struct DeepSeekStreamingTests {

    // MARK: - Fixture

    struct Fixture {
        let provider: DeepSeekProvider
        let transport: FakeHTTPTransport
        let instance: ProviderInstance
        let seed: RequestConfigSeed
        let credentials: CredentialStore
    }

    private func makeFixture() throws -> Fixture {
        let credentials = CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: InMemoryCredentialMetadataRepository()
        )
        let reference = CredentialReference(id: "cred-1")
        try credentials.provision(SecretValue("sk-test-9f3a7c"), as: reference)

        let instance = ProviderInstance(
            id: ProviderInstanceID(rawValue: "pi-1"),
            providerID: .deepSeek,
            displayName: "DeepSeek",
            baseURL: URL(string: "https://api.deepseek.com"),
            configRevision: .initial,
            credentialReference: reference
        )

        let transport = FakeHTTPTransport()
        return Fixture(
            provider: DeepSeekProvider(transport: transport),
            transport: transport,
            instance: instance,
            seed: RequestConfigSeed(
                instance: instance,
                modelID: ModelID(rawValue: "deepseek-flash"),
                credentialBinding: CredentialBindingSnapshot(reference: reference, generation: 1)
            ),
            credentials: credentials
        )
    }

    private func request() -> ProviderChatRequest {
        ProviderChatRequest(
            modelID: ModelID(rawValue: "deepseek-flash"),
            messages: [ProviderChatMessage(role: .user, content: "Hello")]
        )
    }

    /// Wraps payloads as an SSE stream, terminated the way DeepSeek terminates one.
    private func sse(_ payloads: [String], terminated: Bool = true) -> [String] {
        var frames = payloads.map { "data: \($0)\n\n" }
        if terminated { frames.append("data: [DONE]\n\n") }
        return frames
    }

    private func drain(
        _ stream: AsyncThrowingStream<DeepSeekStreamChunk, Error>
    ) async throws -> [DeepSeekStreamChunk] {
        var chunks: [DeepSeekStreamChunk] = []
        for try await chunk in stream { chunks.append(chunk) }
        return chunks
    }

    private func text(of chunk: DeepSeekStreamChunk) -> String? {
        chunk.choices?.first?.delta?.content
    }

    private func reasoning(of chunk: DeepSeekStreamChunk) -> String? {
        chunk.choices?.first?.delta?.reasoning_content
    }

    // MARK: - What goes out

    @Test("the request asks for a stream and accepts one")
    func requestAsksForAStream() async throws {
        let f = try makeFixture()
        f.transport.enqueueStream(sse([#"{"id":"c1","choices":[{"index":0,"delta":{"content":"hi"}}]}"#]))

        _ = try await drain(try await f.provider.stream(request(), seed: f.seed, instance: f.instance, credentials: f.credentials))

        let sent = try #require(f.transport.lastRequest)
        guard let body = sent.body,
              let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            Issue.record("expected a JSON body")
            return
        }
        #expect(json["stream"] as? Bool == true, "this path exists to ask for streaming")
        #expect(sent.headers["Accept"] == "text/event-stream")
        #expect(sent.url.absoluteString == "https://api.deepseek.com/chat/completions")
    }

    @Test("streaming does not invent request options either")
    func noInventedOptions() async throws {
        let f = try makeFixture()
        f.transport.enqueueStream(sse([]))

        _ = try? await drain(try await f.provider.stream(request(), seed: f.seed, instance: f.instance, credentials: f.credentials))

        guard let body = f.transport.lastRequest?.body,
              let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            Issue.record("expected a JSON body")
            return
        }

        // Same constraint as the non-streaming path. `reasoning_effort` and the rest are
        // capability-validated, and capability does not exist yet.
        #expect(Set(json.keys) == ["model", "messages", "stream"], "unexpected keys: \(json.keys.sorted())")
    }

    // MARK: - What comes back

    @Test("content deltas arrive in order")
    func contentDeltasArrive() async throws {
        let f = try makeFixture()
        f.transport.enqueueStream(sse([
            #"{"id":"c1","choices":[{"index":0,"delta":{"role":"assistant","content":""}}]}"#,
            #"{"id":"c1","choices":[{"index":0,"delta":{"content":"Hel"}}]}"#,
            #"{"id":"c1","choices":[{"index":0,"delta":{"content":"lo"}}]}"#,
        ]))

        let chunks = try await drain(try await f.provider.stream(request(), seed: f.seed, instance: f.instance, credentials: f.credentials))

        #expect(chunks.map { text(of: $0) } == ["", "Hel", "lo"])
    }

    @Test("reasoning arrives as deltas alongside the answer")
    func reasoningDeltasArrive() async throws {
        let f = try makeFixture()
        f.transport.enqueueStream(sse([
            #"{"id":"c1","choices":[{"index":0,"delta":{"reasoning_content":"because "}}]}"#,
            #"{"id":"c1","choices":[{"index":0,"delta":{"reasoning_content":"of this"}}]}"#,
            #"{"id":"c1","choices":[{"index":0,"delta":{"content":"answer"}}]}"#,
        ]))

        let chunks = try await drain(try await f.provider.stream(request(), seed: f.seed, instance: f.instance, credentials: f.credentials))

        // Not a separate phase: reasoning deltas and content deltas come through the
        // same channel, and nothing here may assume the reasoning all arrives first.
        #expect(chunks.map { reasoning(of: $0) } == ["because ", "of this", nil])
        #expect(chunks.map { text(of: $0) } == [nil, nil, "answer"])
    }

    @Test("the final chunk carries a finish reason and its usage")
    func finalChunkCarriesFinishReasonAndUsage() async throws {
        let f = try makeFixture()
        f.transport.enqueueStream(sse([
            #"{"id":"c1","choices":[{"index":0,"delta":{"content":"done"}}]}"#,
            #"{"id":"c1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":9,"completion_tokens":3,"total_tokens":12}}"#,
        ]))

        let chunks = try await drain(try await f.provider.stream(request(), seed: f.seed, instance: f.instance, credentials: f.credentials))

        #expect(chunks.count == 2, "a chunk with no content is still a chunk")
        #expect(chunks.last?.choices?.first?.finish_reason == "stop")
        #expect(chunks.last?.usage?.total_tokens == 12)
        #expect(chunks.last?.id == "c1")
    }

    @Test("a chunk with no content at all is not malformed")
    func contentlessChunkIsNotMalformed() async throws {
        let f = try makeFixture()
        // DeepSeek's last chunk before the terminator looks exactly like this: one
        // choice, nothing in the delta, a non-empty finish reason. Treating it as
        // malformed would fail every stream at the moment it succeeded.
        f.transport.enqueueStream(sse([
            #"{"id":"c1","choices":[{"index":0,"delta":{"content":"x"}}]}"#,
            #"{"id":"c1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}"#,
        ]))

        let chunks = try await drain(try await f.provider.stream(request(), seed: f.seed, instance: f.instance, credentials: f.credentials))

        #expect(chunks.count == 2)
        #expect(chunks.last?.choices?.first?.delta?.content == nil)
        #expect(chunks.last?.choices?.first?.finish_reason == "stop")
    }

    @Test("the terminator ends the stream normally")
    func terminatorEndsTheStream() async throws {
        let f = try makeFixture()
        f.transport.enqueueStream(sse([#"{"id":"c1","choices":[{"delta":{"content":"x"}}]}"#]))

        // Reaching here without throwing is the assertion: `[DONE]` is a clean end, and
        // it must not be decoded as a chunk.
        let chunks = try await drain(try await f.provider.stream(request(), seed: f.seed, instance: f.instance, credentials: f.credentials))
        #expect(chunks.count == 1)
    }

    // MARK: - How it can stop

    @Test("a stream that ends without its terminator is an interrupted stream")
    func missingTerminatorIsInterrupted() async throws {
        let f = try makeFixture()
        f.transport.enqueueStream(sse([#"{"id":"c1","choices":[{"delta":{"content":"partial"}}]}"#], terminated: false))

        var failure: ProviderError?
        do {
            _ = try await drain(try await f.provider.stream(request(), seed: f.seed, instance: f.instance, credentials: f.credentials))
        } catch let error as ProviderError {
            failure = error
        }

        guard case .streamInterrupted(let deliveredOutput, _) = failure else {
            Issue.record("expected .streamInterrupted, got \(String(describing: failure))")
            return
        }
        #expect(deliveredOutput, "the caller had already received a chunk")
    }

    @Test("a stream that dies before the terminator is interrupted with the transport's fact")
    func transportFailureIsClassified() async throws {
        let f = try makeFixture()
        f.transport.enqueueStream(
            sse([#"{"id":"c1","choices":[{"delta":{"reasoning_content":"thinking"}}]}"#], terminated: false),
            thenFailWith: .streamInterrupted(deliveredOutput: true, reason: "URLError code -1005")
        )

        var failure: ProviderError?
        do {
            _ = try await drain(try await f.provider.stream(request(), seed: f.seed, instance: f.instance, credentials: f.credentials))
        } catch let error as ProviderError {
            failure = error
        }

        guard case .streamInterrupted(let deliveredOutput, _) = failure else {
            Issue.record("expected .streamInterrupted, got \(String(describing: failure))")
            return
        }
        // Partial reasoning is partial output. It counts.
        #expect(deliveredOutput)
    }

    @Test("a chunk that is not the expected shape is malformed, not skipped")
    func malformedChunkFails() async throws {
        let f = try makeFixture()
        f.transport.enqueueStream(sse([
            #"{"id":"c1","choices":[{"delta":{"content":"x"}}]}"#,
            "not json at all",
        ]))

        var failure: ProviderError?
        do {
            _ = try await drain(try await f.provider.stream(request(), seed: f.seed, instance: f.instance, credentials: f.credentials))
        } catch let error as ProviderError {
            failure = error
        }

        guard case .malformedResponse = failure else {
            Issue.record("expected .malformedResponse, got \(String(describing: failure))")
            return
        }
    }

    @Test("a stream whose bytes are not text is malformed, not quietly skipped")
    func malformedSSEFails() async throws {
        let f = try makeFixture()
        // 0xFF can never start a valid UTF-8 sequence. Substituting U+FFFD instead would
        // put a corrupted answer in front of the user with nothing to distinguish it
        // from what the model actually said.
        f.transport.enqueueStream(bytes: [
            Data("data: ".utf8) + Data([0xFF, 0xFE]) + Data("\n\n".utf8)
        ])

        var failure: ProviderError?
        do {
            _ = try await drain(try await f.provider.stream(request(), seed: f.seed, instance: f.instance, credentials: f.credentials))
        } catch let error as ProviderError {
            failure = error
        }

        guard case .malformedResponse = failure else {
            Issue.record("expected .malformedResponse, got \(String(describing: failure))")
            return
        }
    }

    @Test("a connection that dies before the model produces anything says so")
    func disconnectBeforeFirstEvent() async throws {
        let f = try makeFixture()
        f.transport.enqueueStream(
            [],
            thenFailWith: .streamInterrupted(deliveredOutput: false, reason: "URLError code -1005")
        )

        var failure: ProviderError?
        do {
            _ = try await drain(try await f.provider.stream(request(), seed: f.seed, instance: f.instance, credentials: f.credentials))
        } catch let error as ProviderError {
            failure = error
        }

        guard case .streamInterrupted(let deliveredOutput, _) = failure else {
            Issue.record("expected .streamInterrupted, got \(String(describing: failure))")
            return
        }
        // The transport observed this, and the adapter must not lose it on the way up:
        // "nothing was produced" and "the answer was cut off" lead to different handling.
        #expect(!deliveredOutput, "the model never produced anything before the connection died")
    }

    @Test("a parser failure becomes a Zen error, and an unterminated one keeps its distinction")
    func parserFailuresAreMapped() {
        #expect(
            DeepSeekProvider.providerError(from: .invalidUTF8, deliveredOutput: false)
                == .malformedResponse("a stream event was not valid UTF-8")
        )
        #expect(
            DeepSeekProvider.providerError(from: .bufferLimitExceeded(limit: 64), deliveredOutput: false)
                == .malformedResponse("a stream event exceeded the 64-byte reassembly bound")
        )
        // The parser can say the terminator never arrived; it cannot know whether
        // anything was delivered before that, so the caller passes the fact in.
        #expect(
            DeepSeekProvider.providerError(from: .unterminatedStream, deliveredOutput: true)
                == .streamInterrupted(deliveredOutput: true, reason: "the stream ended without reaching its terminator")
        )
        #expect(
            DeepSeekProvider.providerError(from: .unterminatedStream, deliveredOutput: false)
                == .streamInterrupted(deliveredOutput: false, reason: "the stream ended without reaching its terminator")
        )
    }

    @Test("a refused stream is refused by status, before any chunk")
    func nonSuccessStatusIsMapped() async throws {
        let f = try makeFixture()
        f.transport.failStream(with: .httpStatus(
            HTTPResponse(status: 429, headers: ["Retry-After": "30"], json: #"{"error":{"message":"slow down"}}"#)
        ))

        var failure: ProviderError?
        do {
            _ = try await f.provider.stream(request(), seed: f.seed, instance: f.instance, credentials: f.credentials)
        } catch let error as ProviderError {
            failure = error
        }

        // The same table the non-streaming path uses: one status, one meaning.
        #expect(failure == .rateLimited(retryAfter: 30))
    }

    @Test("cancellation is cancelled, not a failure")
    func cancellationIsItsOwnOutcome() async throws {
        let f = try makeFixture()
        f.transport.failStream(with: .cancelled)

        var failure: ProviderError?
        do {
            _ = try await f.provider.stream(request(), seed: f.seed, instance: f.instance, credentials: f.credentials)
        } catch let error as ProviderError {
            failure = error
        }

        #expect(failure == .cancelled)
    }

    // MARK: - Frozen configuration, unchanged

    @Test("an edited instance is refused before anything is sent")
    func editedInstanceIsRefusedBeforeDispatch() async throws {
        let f = try makeFixture()
        var edited = f.instance
        edited.configRevision = ConfigRevision(rawValue: "2")
        f.transport.enqueueStream(sse([]))

        var failure: ProviderError?
        do {
            _ = try await f.provider.stream(request(), seed: f.seed, instance: edited, credentials: f.credentials)
        } catch let error as ProviderError {
            failure = error
        }

        guard case .configurationMismatch = failure else {
            Issue.record("expected .configurationMismatch, got \(String(describing: failure))")
            return
        }
        #expect(f.transport.requestCount == 0, "a refused run must not reach the network at all")
    }

    @Test("a credential change since the freeze is refused")
    func credentialChangeIsRefused() async throws {
        let f = try makeFixture()
        try f.credentials.rebind(SecretValue("sk-other"), as: CredentialReference(id: "cred-1"), principalFingerprint: "acct-b")
        f.transport.enqueueStream(sse([]))

        var failure: ProviderError?
        do {
            _ = try await f.provider.stream(request(), seed: f.seed, instance: f.instance, credentials: f.credentials)
        } catch let error as ProviderError {
            failure = error
        }

        guard case .configurationMismatch = failure else {
            Issue.record("expected .configurationMismatch, got \(String(describing: failure))")
            return
        }
        #expect(f.transport.requestCount == 0)
    }

    // MARK: - No retry

    @Test("a stream that fails makes exactly one request")
    func failedStreamIsNotRetried() async throws {
        let f = try makeFixture()
        f.transport.enqueueStream(
            sse([#"{"id":"c1","choices":[{"delta":{"content":"x"}}]}"#], terminated: false),
            thenFailWith: .streamInterrupted(deliveredOutput: true, reason: "URLError code -1005")
        )

        _ = try? await drain(try await f.provider.stream(request(), seed: f.seed, instance: f.instance, credentials: f.credentials))

        #expect(
            f.transport.requestCount == 1,
            """
            expected one attempt, made \(f.transport.requestCount). Re-sending a \
            streaming POST asks the model to generate the answer again while the caller \
            still believes it is watching the first one (Agent Runtime.md:344).
            """
        )
    }
}

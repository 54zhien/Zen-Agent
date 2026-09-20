import Foundation

/// The DeepSeek adapter.
///
/// Two ways in, one shape: `complete` returns a whole response, `stream` yields DeepSeek's
/// chunks as they arrive. Both verify the frozen configuration before resolving a secret,
/// both build their request from the same endpoint resolution, and neither retries.
///
/// It speaks `ModelProvider` and `HTTPTransport`, so it neither invents its own protocol
/// nor reaches for `URLSession`. A CI check enforces the second half.
struct DeepSeekProvider: ModelProvider {

    /// Verified against DeepSeek's official documentation, not from memory.
    ///
    /// `deepseek-chat` and `deepseek-reasoner` were retired and no longer appear in the
    /// model list; a run naming them would fail at the provider rather than here, which
    /// is why they are absent rather than present-and-deprecated.
    static let modelIDs: [ModelID] = [
        ModelID(rawValue: "deepseek-flash"),
        ModelID(rawValue: "deepseek-v4-pro"),
    ]

    static let defaultBaseURL = URL(string: "https://api.deepseek.com")!

    let id = ProviderID.deepSeek
    let transport: any HTTPTransport
    /// The same policy the transport is given. The transport reads `transportInactivity`
    /// from it and this adapter reads `firstEvent` and `betweenEvents`, so the two
    /// deadlines that must stay distinct are configured in one place rather than
    /// drifting apart in two.
    let streamTimeouts: StreamTimeoutPolicy

    init(
        transport: any HTTPTransport,
        streamTimeouts: StreamTimeoutPolicy = .default
    ) {
        self.transport = transport
        self.streamTimeouts = streamTimeouts
    }

    /// Where this run must send its request.
    ///
    /// **One resolution, both paths.** The adapter used to carry an endpoint of its own
    /// alongside the instance's, which is two sources of truth for one URL — and the
    /// `Authorization` header goes wherever the URL points. A second endpoint that
    /// streaming could quietly use while non-streaming used the first is the shape of
    /// bug where a credential is sent somewhere the run was never frozen against.
    ///
    /// The instance's endpoint wins when it has one; the provider default is the fallback.
    ///
    /// **This is the freezing-time answer, not the sending-time one.** What it returns
    /// goes into the seed, and the request is later built from the seed — so the default
    /// host above cannot move underneath a run that has already been frozen. If it ever
    /// does, `FrozenConfiguration` refuses the run rather than quietly redirecting it,
    /// credential and all.
    ///
    /// A complete request URL rather than a base: the path is as much a part of where the
    /// request goes as the host, and freezing half of it would leave the other half free
    /// to change.
    static func resolvedEndpoint(for instance: ProviderInstance) -> URL {
        (instance.baseURL ?? Self.defaultBaseURL).appending(path: "chat/completions")
    }

    // MARK: - ModelProvider

    func knownModels(for instance: ProviderInstance) -> [ModelDescriptor] {
        Self.modelIDs.map {
            ModelDescriptor(id: $0, providerInstanceID: instance.id, displayName: $0.rawValue)
        }
    }

    func descriptor(for modelID: ModelID, in instance: ProviderInstance) -> ModelDescriptor? {
        knownModels(for: instance).first { $0.id == modelID }
    }

    // MARK: - Completion

    /// Sends one non-streaming chat completion.
    ///
    /// The order is the design: verify the frozen configuration, then resolve the secret,
    /// then build the request, then send. Resolving before verifying would fetch a secret
    /// for a request that is about to be refused, and verifying after building would mean
    /// the secret had already been placed in a request that may not go out.
    ///
    /// **No retry, at any point.** Not on 429, not on 503, not on a dropped connection.
    /// The error carries a `RetryDisposition` for a higher layer to act on; this function
    /// makes exactly one attempt and returns.
    func complete(
        _ request: ProviderChatRequest,
        seed: RequestConfigSeed,
        instance: ProviderInstance,
        credentials: any CredentialStoring
    ) async throws -> ProviderResponse {
        try FrozenConfiguration.validate(
            seed: seed,
            modelID: request.modelID,
            instance: instance,
            credentials: credentials,
            resolvedEndpoint: Self.resolvedEndpoint(for: instance)
        )

        guard instance.credentialReference != nil else {
            // Unreachable: `validate` refuses a missing reference. Kept as a guard rather
            // than trusting the seed blind so a future reordering of the checks fails
            // visibly instead of resolving a secret for an instance with none.
            throw ProviderError.credentialMissing
        }
        let secret = try Self.resolveSecret(seed.credentialBinding, from: credentials)

        let httpRequest = try makeHTTPRequest(
            request, secret: secret, endpoint: seed.endpoint, streaming: false
        )

        let httpResponse: HTTPResponse
        do {
            httpResponse = try await transport.send(httpRequest)
        } catch {
            // Translated, not propagated. Letting `HTTPTransportError` through would put
            // a transport-layer type in front of the Runtime — the exact leak this
            // abstraction exists to prevent, and one that would make every later
            // transport's vocabulary the Runtime's problem.
            throw Self.providerError(from: error, deliveredOutput: false)
        }

        guard (200..<300).contains(httpResponse.status) else {
            throw Self.error(for: httpResponse)
        }
        return try Self.normalise(httpResponse.body)
    }

    // MARK: - Streaming completion

    /// Streams one chat completion, yielding DeepSeek's own chunks.
    ///
    /// **Raw, not normalised.** These elements are DeepSeek's wire shape. Mapping them
    /// onto something provider-neutral is its own increment, and doing it here would
    /// mean designing that vocabulary against a single provider — which is exactly what
    /// these increments exist to avoid.
    ///
    /// The order matches `complete`: verify the frozen configuration, resolve the
    /// secret, build the request, then send. Nothing reaches the network for a run that
    /// is about to be refused.
    ///
    /// **No retry**, here or anywhere below. A streaming POST cannot prove the request
    /// was never accepted, so the notes forbid connection-level retry outright
    /// (`Agent Runtime.md:341-343`); the caller gets a `RetryDisposition` and makes that
    /// decision itself.
    func stream(
        _ request: ProviderChatRequest,
        seed: RequestConfigSeed,
        instance: ProviderInstance,
        credentials: any CredentialStoring
    ) async throws -> AsyncThrowingStream<DeepSeekStreamChunk, Error> {
        try FrozenConfiguration.validate(
            seed: seed,
            modelID: request.modelID,
            instance: instance,
            credentials: credentials,
            resolvedEndpoint: Self.resolvedEndpoint(for: instance)
        )

        guard instance.credentialReference != nil else {
            // Unreachable, as in `complete`: `validate` refuses a missing reference.
            throw ProviderError.credentialMissing
        }
        let secret = try Self.resolveSecret(seed.credentialBinding, from: credentials)

        let httpRequest = try makeHTTPRequest(
            request, secret: secret, endpoint: seed.endpoint, streaming: true
        )

        let upstream: HTTPStream
        do {
            upstream = try await transport.stream(httpRequest)
        } catch {
            throw Self.providerError(from: error, deliveredOutput: false)
        }

        return Self.chunks(from: upstream, timeouts: streamTimeouts)
    }

    /// Reassembles DeepSeek's chunks out of the byte stream.
    ///
    /// The three layers are composed here and nowhere else: bytes from the transport,
    /// SSE framing from the parser, and DeepSeek's JSON from `decodeStreamChunk`. Each
    /// is separately testable; this is where they meet.
    ///
    /// The deadline here is rearmed **only by an event that carried model output**. A
    /// keep-alive cannot reach this point — the parser consumes comments without
    /// dispatching them — so a provider that heartbeats for ten minutes while it thinks
    /// keeps its connection open under the transport's deadline and still runs out the
    /// one here. That separation is the point: the two facts are different, so they get
    /// different timers.
    private static func chunks(
        from upstream: HTTPStream,
        timeouts: StreamTimeoutPolicy
    ) -> AsyncThrowingStream<DeepSeekStreamChunk, Error> {
        let progress = StreamProgress()

        return AsyncThrowingStream { continuation in
            // Every way this stream can end — the consumer cancelling, a deadline
            // expiring, a chunk that will not decode, the protocol saying `[DONE]` —
            // must also end the transfer behind it. Otherwise ending the answer and
            // ending the request are two different things, and only the first happens.
            //
            // One call, one hop. Nothing here relies on this task's cancellation
            // reaching a nested stream's iterator, which is the assumption CI showed to
            // be false when this was wired through `onTermination` and a captured task.
            continuation.onTermination = { _ in upstream.cancel() }

            Task {
                await StreamDeadline.run(
                    progress: progress,
                    first: timeouts.firstEvent,
                    subsequent: timeouts.betweenEvents,
                    checkInterval: timeouts.checkInterval,
                    onTimeout: { elapsed in
                        continuation.finish(throwing: ProviderError.streamProgressTimeout(
                            // Which wait ran out, taken from the **same locked read** that
                            // chose the window: no output yet means the model never
                            // started, output that stopped means it stalled partway.
                            //
                            // Deliberately not `progress.hasAdvanced` here. Asking again
                            // is a second read, and a chunk arriving between the two
                            // flips "never started" into "stopped partway" - a report
                            // about a stall that did not happen.
                            phase: elapsed.hadAdvanced ? .betweenEvents : .awaitingFirstEvent,
                            after: elapsed.after
                        ))
                    },
                    reading: {
                        // Declared inside the reader, so nothing outlives the task that
                        // owns it and no `var` is captured across a suspension point.
                        var parser = SSEParser()
                        do {
                            for try await chunk in upstream.body {
                                for element in try parser.consume(chunk) {
                                    switch element {
                                    case .done:
                                        continuation.finish()
                                        return
                                    case .event(let event):
                                        // A bare `data:` line is legal SSE and the parser
                                        // deliberately dispatches it with an empty payload.
                                        // It carries no chunk, so it is skipped rather than
                                        // decoded — failing an answer over a heartbeat is
                                        // not strictness worth having.
                                        let payload = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
                                        guard !payload.isEmpty else { continue }

                                        let decoded = try decodeStreamChunk(payload)
                                        // Rearmed by **output**, not merely by a chunk
                                        // arriving. DeepSeek's first chunk carries a role
                                        // and an empty content string, and a proxy that
                                        // kept sending `delta: {}` would otherwise re-arm
                                        // this forever — the stall it exists to catch would
                                        // never be caught, and the run would hang with
                                        // nothing produced.
                                        if Self.carriesOutput(decoded) { progress.advanced() }
                                        continuation.yield(decoded)
                                    }
                                }
                            }
                            // The bytes ended without the terminator ever arriving.
                            try parser.finish()
                            continuation.finish()
                        } catch let failure as SSEParserError {
                            continuation.finish(
                                throwing: providerError(from: failure, deliveredOutput: progress.hasAdvanced)
                            )
                        } catch {
                            continuation.finish(throwing: providerError(from: error, deliveredOutput: progress.hasAdvanced))
                        }
                    }
                )
            }
        }
    }

    /// Whether a chunk carries anything the model actually produced.
    ///
    /// The distinction the whole two-deadline design rests on. An empty `content` string,
    /// an absent delta and a `finish_reason`-only chunk are all chunks and none of them is
    /// output — so a stream of them is evidence the connection is alive and evidence of
    /// nothing else.
    static func carriesOutput(_ chunk: DeepSeekStreamChunk) -> Bool {
        guard let delta = chunk.choices?.first?.delta else { return false }
        return !(delta.content ?? "").isEmpty || !(delta.reasoning_content ?? "").isEmpty
    }

    /// One event payload to one chunk.
    ///
    /// Fails rather than guessing. A payload that is not the expected shape means the
    /// stream cannot be trusted, and a best-effort parse would put a half-understood
    /// chunk in front of the user as though it were the model's output.
    static func decodeStreamChunk(_ data: String) throws -> DeepSeekStreamChunk {
        do {
            return try JSONDecoder().decode(DeepSeekStreamChunk.self, from: Data(data.utf8))
        } catch {
            throw ProviderError.malformedResponse("a streaming chunk did not match the expected shape")
        }
    }

    /// A parser failure, in Zen's vocabulary.
    ///
    /// `deliveredOutput` is threaded in rather than assumed: the parser cannot know
    /// whether its caller had already handed anything onward, and that fact decides
    /// whether the result is a stream that was cut short or one that never started.
    static func providerError(from error: SSEParserError, deliveredOutput: Bool) -> ProviderError {
        switch error {
        case .unterminatedStream:
            return .streamInterrupted(
                deliveredOutput: deliveredOutput,
                reason: "the stream ended without reaching its terminator"
            )
        case .invalidUTF8:
            return .malformedResponse("a stream event was not valid UTF-8")
        case .malformedFrame(let reason):
            return .malformedResponse(reason)
        case .bufferLimitExceeded(let limit):
            return .malformedResponse("a stream event exceeded the \(limit)-byte reassembly bound")
        }
    }

    // MARK: - Request

    /// The one place a chat-completions request is built, for both paths.
    ///
    /// `streaming` changes exactly two things — the flag in the body and the `Accept`
    /// header — so the endpoint, the credential and the message mapping cannot drift
    /// between the streamed and non-streamed request.
    private func makeHTTPRequest(
        _ request: ProviderChatRequest,
        secret: SecretValue,
        endpoint: URL,
        streaming: Bool
    ) throws -> HTTPRequest {
        let body = DeepSeekChatRequest(
            model: request.modelID.rawValue,
            messages: request.messages.map {
                DeepSeekChatRequest.Message(role: $0.role.rawValue, content: $0.content)
            },
            stream: streaming
        )

        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(body)
        } catch {
            throw ProviderError.invalidRequest("the request body could not be encoded")
        }

        return HTTPRequest(
            method: .post,
            // The frozen endpoint, verbatim. Nothing here re-resolves it: a URL built at
            // send time from a default constant is exactly the drift the seed now
            // prevents.
            url: endpoint,
            headers: [
                "Content-Type": "application/json",
                // The secret's only appearance outside the keychain, and it lives here
                // for the duration of one call. `HTTPRequest` redacts this header if
                // anything prints the request.
                "Authorization": "Bearer \(secret.revealed)",
                "Accept": streaming ? "text/event-stream" : "application/json",
            ],
            body: encoded
        )
    }

    // MARK: - Credential resolution

    /// The last moment the secret exists. Deliberately not stored, not cached, and not
    /// returned to any caller above this adapter.
    ///
    /// Resolved through the **frozen binding**, not the instance's current
    /// reference: one critical-section read re-checks status and generation against
    /// what the run was frozen with. A rebind committed between `validate` and
    /// here is refused instead of silently substituting the new account's secret —
    /// validation passed against generation N, so the secret must come from the
    /// key versioned with N.
    private static func resolveSecret(
        _ binding: CredentialBindingSnapshot,
        from credentials: any CredentialStoring
    ) throws -> SecretValue {
        do {
            guard let secret = try credentials.resolve(
                frozenReference: binding.reference,
                generation: binding.generation
            ) else {
                throw ProviderError.credentialMissing
            }
            return secret
        } catch let error as CredentialError {
            switch error {
            case .notFound:
                throw ProviderError.credentialMissing
            case .unavailable(_, let reason):
                throw ProviderError.credentialTemporarilyUnavailable(reason: reason)
            case .authenticationRequired:
                throw ProviderError.credentialRejected
            case .alreadyExists:
                throw ProviderError.configurationMismatch("the credential store refused a read")
            case .bindingMoved(_, let frozenGeneration, let currentGeneration):
                // What `validate` checked has already moved by the time the secret
                // was read. The same refusal, on the same grounds: the run goes out
                // under the identity it was frozen with, or not at all.
                throw ProviderError.configurationMismatch(
                    """
                    the credential binding moved between validation and resolution \
                    (generation \(frozenGeneration) → \(currentGeneration)). The run was \
                    frozen against the old generation, so it is refused rather than sent \
                    under the new account's secret.
                    """
                )
            case .failed(_, let reason):
                // Damaged storage, not a damaged credential. The provider never saw
                // it, so this is not a rejection; waiting will not repair it, so it
                // is not the temporary-unavailable case either.
                throw ProviderError.credentialStorageFailed(reason: reason)
            }
        }
    }

    /// Anything a transport can throw, in Zen's vocabulary.
    ///
    /// An unrecognised error still becomes `transportFailure` rather than escaping: a
    /// caller above this adapter must never have to know which transport is underneath,
    /// and "the request failed and we do not know why" is the honest description of an
    /// error this layer cannot classify.
    /// Anything a transport or parser can throw, in Zen's vocabulary.
    ///
    /// `deliveredOutput` is the caller's knowledge, not this function's, and it is asked
    /// for rather than inferred because this layer cannot infer it: whether the **model**
    /// produced anything is knowable only where chunks are decoded, and the transport's
    /// byte count is a different fact. An earlier version forwarded the transport's count
    /// here, which made a stream of keep-alive comments look like a partially delivered
    /// answer and forbade a retry the notes permit.
    static func providerError(from error: Error, deliveredOutput: Bool) -> ProviderError {
        switch error {
        case let transport as HTTPTransportError:
            switch transport {
            case .networkFailure(let reason):
                return .transportFailure(reason)
            case .cancelled:
                return .cancelled
            case .httpStatus(let response):
                // The same mapping `complete` applies to a non-streaming response. One
                // status→error table, used by both paths, so a 401 cannot come to mean
                // one thing when streamed and another when not.
                return Self.error(for: response)
            case .inactivityTimeout(let elapsed):
                // Translated rather than folded into `streamInterrupted`. The two are
                // diagnosed differently — one is a read timeout or a provider that
                // stopped sending keep-alives, the other is a connection that dropped —
                // and collapsing them would send someone looking in the wrong place.
                return .streamInactivityTimeout(after: elapsed, deliveredOutput: deliveredOutput)
            case .streamInterrupted(_, let reason):
                // The transport's own `deliveredData` is deliberately dropped. It counts
                // bytes, and bytes include keep-alive comments — which are evidence the
                // connection is alive and evidence of nothing else. The caller's
                // `deliveredOutput` is the fact the replay rule turns on.
                return .streamInterrupted(deliveredOutput: deliveredOutput, reason: reason)
            }
        case is CancellationError:
            // Swift's own cancellation, which a real transport can surface instead of
            // translating it. Same meaning, so same case.
            return .cancelled
        case let provider as ProviderError:
            // Already Zen's vocabulary. Passing it through is not a shortcut — it is the
            // only answer that keeps which failure it was. Re-wrapping would turn a
            // specific refusal into a generic transport failure.
            return provider
        default:
            return .transportFailure("the transport failed without a recognisable reason")
        }
    }

    // MARK: - Error mapping

    /// HTTP status to a Zen error.
    ///
    /// The status code decides the *case*; the provider's own message may inform the
    /// text of an associated value but never becomes a type. A DeepSeek error body that
    /// reached the Runtime would make every later Provider's failures a special case of
    /// DeepSeek's.
    static func error(for response: HTTPResponse) -> ProviderError {
        switch response.status {
        case 400:
            return .invalidRequest(diagnostic(from: response.body))
        case 401:
            // Only the error changes. Nothing here — and nothing above — may delete the
            // credential, log the user out, or re-provision: a 401 is evidence about the
            // credential, not an instruction to destroy it.
            return .credentialRejected
        case 402:
            return .insufficientBalance
        case 422:
            return .invalidParameters(diagnostic(from: response.body))
        case 429:
            return .rateLimited(retryAfter: retryAfter(from: response.headers))
        case 503:
            return .overloaded
        default:
            return response.status >= 500
                ? .serverError(status: response.status)
                : .invalidRequest(diagnostic(from: response.body))
        }
    }

    /// A short, controlled message from the provider's error envelope.
    ///
    /// Only the parsed `message` field, truncated — never the raw body, which could be
    /// arbitrarily large and could echo parts of the request. And it is a *value* inside
    /// a Zen error, not a type anything switches on.
    static func diagnostic(from body: Data) -> String {
        guard let decoded = try? JSONDecoder().decode(DeepSeekErrorResponse.self, from: body),
              let message = decoded.error?.message,
              !message.isEmpty
        else {
            return "the provider rejected the request without a readable message"
        }
        return String(message.prefix(200))
    }

    static func retryAfter(from headers: [String: String]) -> TimeInterval? {
        // Header names are case-insensitive, and providers are inconsistent about it.
        guard let raw = headers.first(where: { $0.key.lowercased() == "retry-after" })?.value else {
            return nil
        }
        return TimeInterval(raw.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Response normalisation

    /// DeepSeek's JSON to a provider-neutral response.
    ///
    /// Fails rather than guessing. A body without an id or without any choice is not a
    /// response with missing fields — it is not a response, and treating it as an empty
    /// one would show the user a blank answer where a failure occurred.
    static func normalise(_ body: Data) throws -> ProviderResponse {
        let decoded: DeepSeekChatResponse
        do {
            decoded = try JSONDecoder().decode(DeepSeekChatResponse.self, from: body)
        } catch {
            throw ProviderError.malformedResponse("the response body did not match the expected shape")
        }

        guard let id = decoded.id, !id.isEmpty else {
            throw ProviderError.malformedResponse("the response carried no id")
        }
        guard let choice = decoded.choices?.first else {
            throw ProviderError.malformedResponse("the response carried no choices")
        }

        return ProviderResponse(
            id: id,
            text: choice.message?.content ?? "",
            // Absent, not empty, when the model is not in thinking mode — the two mean
            // different things to anything deciding whether to show a reasoning section.
            reasoning: choice.message?.reasoning_content,
            finishReason: FinishReason(wire: choice.finish_reason),
            usage: decoded.usage.map {
                ProviderTokenUsage(
                    promptTokens: $0.prompt_tokens ?? 0,
                    completionTokens: $0.completion_tokens ?? 0,
                    totalTokens: $0.total_tokens ?? 0
                )
            }
        )
    }
}

extension FinishReason {
    /// An unrecognised reason is preserved rather than flattened to `.stop`.
    ///
    /// A Provider that adds a stop reason must not cause its responses to be reported as
    /// clean completions — that is the shape of bug where a truncated answer looks
    /// finished.
    init(wire: String?) {
        switch wire {
        case "stop": self = .stop
        case "length": self = .length
        case "content_filter": self = .contentFilter
        case "tool_calls": self = .toolCalls
        case .some(let other): self = .unknown(other)
        case .none: self = .unknown("absent")
        }
    }
}

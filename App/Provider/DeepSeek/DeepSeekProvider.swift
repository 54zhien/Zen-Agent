import Foundation

/// The DeepSeek adapter.
///
/// Two ways in, one shape: `complete` returns a whole response, `stream` yields normalized
/// provider events as they arrive. Both validate the request against the frozen seed before
/// resolving a secret,
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

    private static let adapterCapabilities: Set<ModelCapability> = [
        .text,
        .streaming,
        .reasoning,
        .tools,
    ]

    static let defaultBaseURL = URL(string: "https://api.deepseek.com")!

    let id = ProviderID.deepSeek
    let transport: any HTTPTransport
    /// The same policy the transport is given. The transport reads `transportInactivity`
    /// and `errorBodyDeadline` from it, and this adapter reads `firstEvent` and
    /// `betweenEvents`, so the deadlines that must stay distinct are configured in one
    /// place rather than drifting apart in two.
    let streamTimeouts: StreamTimeoutPolicy

    var adapterRevision: String { "deepseek-chat-completions.v1" }

    var adapterPromptInstructions: String {
        "Use DeepSeek's chat-completions protocol and preserve structured tool calls."
    }

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
    /// host above cannot move underneath a run that has already been frozen. Execution
    /// never resolves the endpoint again.
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
            ModelDescriptor(
                id: $0,
                providerInstanceID: instance.id,
                displayName: $0.rawValue,
                capabilities: Self.adapterCapabilities
            )
        }
    }

    func descriptor(for modelID: ModelID, in instance: ProviderInstance) -> ModelDescriptor? {
        knownModels(for: instance).first { $0.id == modelID }
    }

    func makeRequestConfigSeed(
        instance: ProviderInstance,
        modelID: ModelID,
        credentialBinding: CredentialBindingSnapshot
    ) throws -> RequestConfigSeed {
        guard instance.providerID == id else {
            throw ProviderError.invalidRequest("provider instance belongs to \(instance.providerID.rawValue)")
        }
        guard descriptor(for: modelID, in: instance) != nil else {
            throw ProviderError.invalidRequest("unknown model \(modelID.rawValue)")
        }

        return RequestConfigSeed(
            instance: instance,
            modelID: modelID,
            credentialBinding: credentialBinding,
            resolvedEndpoint: Self.resolvedEndpoint(for: instance)
        )
    }

    // MARK: - Completion

    /// Sends one non-streaming chat completion.
    ///
    /// The order is the design: validate the request against the frozen seed, then resolve the secret,
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
        credentials: any CredentialStoring
    ) async throws -> ProviderResponse {
        try Self.validate(request: request, against: seed)
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
            throw Self.providerError(from: error, deliveredOutput: false, redacting: secret)
        }

        guard (200..<300).contains(httpResponse.status) else {
            throw Self.error(for: httpResponse, redacting: secret)
        }
        return try Self.normalise(httpResponse.body)
    }

    // MARK: - Streaming completion

    /// Streams one chat completion, yielding provider-neutral events.
    ///
    /// DeepSeek's wire shape stays inside this adapter. The stream exposes only the
    /// provider-neutral contract declared by `ModelProvider`.
    ///
    /// The order matches `complete`: validate the request against the frozen seed, resolve the
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
        credentials: any CredentialStoring
    ) async throws -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        try Self.validate(request: request, against: seed)
        let secret = try Self.resolveSecret(seed.credentialBinding, from: credentials)

        let httpRequest = try makeHTTPRequest(
            request, secret: secret, endpoint: seed.endpoint, streaming: true
        )

        let upstream: HTTPStream
        do {
            upstream = try await transport.stream(httpRequest)
        } catch {
            throw Self.providerError(from: error, deliveredOutput: false, redacting: secret)
        }

        return Self.events(from: upstream, timeouts: streamTimeouts, redacting: secret)
    }

    private static func validate(
        request: ProviderChatRequest,
        against seed: RequestConfigSeed
    ) throws {
        guard request.modelID == seed.modelID else {
            throw ProviderError.configurationMismatch(
                "the run was frozen against model \(seed.modelID.rawValue), not \(request.modelID.rawValue)"
            )
        }
    }

    /// Reassembles DeepSeek's provider-neutral events out of the byte stream.
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
    ///
    /// `redacting` is carried because failures raised after streaming begins can still
    /// contain a refused response body. The value is captured in memory for this stream's
    /// error mapping; it is not persisted or returned as part of the resulting error.
    private static func events(
        from upstream: HTTPStream,
        timeouts: StreamTimeoutPolicy,
        redacting secret: SecretValue
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
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
                        var toolCallAssembler = ToolCallAssembler()
                        do {
                            for try await chunk in upstream.body {
                                for element in try parser.consume(chunk) {
                                    switch element {
                                    case .done:
                                        for toolCall in try toolCallAssembler.finish() {
                                            continuation.yield(.toolCall(toolCall))
                                        }
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
                                        for event in try Self.normalizedEvents(
                                            from: decoded,
                                            assembling: &toolCallAssembler
                                        ) {
                                            continuation.yield(event)
                                        }
                                    }
                                }
                            }
                            // The bytes ended without the terminator ever arriving.
                            try parser.finish()
                            continuation.finish()
                        } catch let failure as SSEParserError {
                            // Parser failures use the dedicated SSEParserError overload.
                            // They contain no provider response body and already have
                            // precise ProviderError mappings, so there is no diagnostic text
                            // here that needs the run secret.
                            continuation.finish(
                                throwing: providerError(from: failure, deliveredOutput: progress.hasAdvanced)
                            )
                        } catch {
                            // Other failures may carry a refused response body, so keep the
                            // run secret on this mapping path for diagnostic redaction.
                            continuation.finish(
                                throwing: providerError(
                                    from: error,
                                    deliveredOutput: progress.hasAdvanced,
                                    redacting: secret
                                )
                            )
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
        return !(delta.content ?? "").isEmpty
            || !(delta.reasoning_content ?? "").isEmpty
            || !(delta.tool_calls ?? []).isEmpty
    }

    static func normalizedEvents(from chunk: DeepSeekStreamChunk) -> [ProviderStreamEvent] {
        var assembler = ToolCallAssembler()
        return (try? normalizedEvents(from: chunk, assembling: &assembler)) ?? []
    }

    private static func normalizedEvents(
        from chunk: DeepSeekStreamChunk,
        assembling assembler: inout ToolCallAssembler
    ) throws -> [ProviderStreamEvent] {
        var events: [ProviderStreamEvent] = []

        if let fragments = chunk.choices?.first?.delta?.tool_calls {
            assembler.append(fragments)
        }

        if let reasoning = chunk.choices?.first?.delta?.reasoning_content, !reasoning.isEmpty {
            events.append(.reasoningDelta(reasoning))
        }
        if let text = chunk.choices?.first?.delta?.content, !text.isEmpty {
            events.append(.textDelta(text))
        }
        if let finishReason = chunk.choices?.first?.finish_reason {
            for toolCall in try assembler.finish() {
                events.append(.toolCall(toolCall))
            }
            events.append(.finish(FinishReason(wire: finishReason)))
        }
        if let usage = chunk.usage {
            events.append(.usage(ProviderTokenUsage(
                promptTokens: usage.prompt_tokens ?? 0,
                completionTokens: usage.completion_tokens ?? 0,
                totalTokens: usage.total_tokens ?? 0
            )))
        }

        return events
    }

    private struct ToolCallAssembly {
        var id = ""
        var name = ""
        var arguments = ""
    }

    private struct ToolCallAssembler {
        private var calls: [Int: ToolCallAssembly] = [:]

        var isEmpty: Bool { calls.isEmpty }

        mutating func append(_ fragments: [DeepSeekToolCallDelta]) {
            for fragment in fragments {
                let index = fragment.index

                var call = calls[index, default: ToolCallAssembly()]
                if let id = fragment.id, !id.isEmpty {
                    call.id = id
                }
                if let name = fragment.function?.name, !name.isEmpty {
                    call.name = name
                }
                if let arguments = fragment.function?.arguments {
                    call.arguments += arguments
                }
                calls[index] = call
            }
        }

        mutating func finish() throws -> [ProviderToolCall] {
            guard !calls.isEmpty else { return [] }

            let result = try calls.keys.sorted().map { index -> ProviderToolCall in
                guard let call = calls[index], !call.id.isEmpty, !call.name.isEmpty else {
                    throw ProviderError.malformedResponse(
                        "a streamed tool call was missing its id or function name"
                    )
                }
                return ProviderToolCall(
                    id: call.id,
                    index: index,
                    name: call.name,
                    argumentsJSON: call.arguments
                )
            }
            calls.removeAll(keepingCapacity: false)
            return result
        }
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
            messages: request.messages.map(Self.makeMessage),
            tools: request.tools.map {
                DeepSeekChatRequest.Tool(
                    type: "function",
                    function: DeepSeekChatRequest.Function(
                        name: $0.name,
                        description: $0.description,
                        parameters: $0.parameters
                    )
                )
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

    private static func makeMessage(_ message: ProviderChatMessage) -> DeepSeekChatRequest.Message {
        switch message {
        case .system(let content):
            return DeepSeekChatRequest.Message(
                role: "system",
                content: content,
                reasoning_content: nil,
                tool_calls: nil,
                tool_call_id: nil
            )
        case .user(let content):
            return DeepSeekChatRequest.Message(
                role: "user",
                content: content,
                reasoning_content: nil,
                tool_calls: nil,
                tool_call_id: nil
            )
        case .assistant(let content, let reasoning, let toolCalls):
            return DeepSeekChatRequest.Message(
                role: "assistant",
                content: content,
                reasoning_content: reasoning,
                tool_calls: toolCalls.map {
                    DeepSeekToolCall(
                        id: $0.id,
                        type: "function",
                        function: DeepSeekToolCallFunction(
                            name: $0.name,
                            arguments: $0.argumentsJSON
                        )
                    )
                },
                tool_call_id: nil
            )
        case .toolResult(let toolCallID, let content):
            return DeepSeekChatRequest.Message(
                role: "tool",
                content: content,
                reasoning_content: nil,
                tool_calls: nil,
                tool_call_id: toolCallID
            )
        }
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
    static func providerError(
        from error: Error,
        deliveredOutput: Bool,
        redacting secret: SecretValue
    ) -> ProviderError {
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
                return Self.error(for: response, redacting: secret)
            case .errorBodyTimeout(let response, _):
                // The same table again, and for the same reason: the status line
                // arrived before the body did, so a request that was refused is still
                // refused and a 401 whose envelope trickled is still a 401. Reporting
                // it as `transportFailure` would turn a refusal into "something went
                // wrong", which is a worse answer than a slow body deserves.
                //
                // The deadline itself stops here. Above the transport, "the envelope
                // was slow" changes nothing a caller can act on — what it can act on is
                // the refusal, and this keeps it. The distinction stays where it is
                // observable, which is the transport and its tests.
                return Self.error(for: response, redacting: secret)
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
    static func error(for response: HTTPResponse, redacting secret: SecretValue) -> ProviderError {
        switch response.status {
        case 400:
            return .invalidRequest(diagnostic(from: response.body, redacting: secret))
        case 401:
            // Only the error changes. Nothing here — and nothing above — may delete the
            // credential, log the user out, or re-provision: a 401 is evidence about the
            // credential, not an instruction to destroy it.
            return .credentialRejected
        case 402:
            return .insufficientBalance
        case 422:
            return .invalidParameters(diagnostic(from: response.body, redacting: secret))
        case 429:
            return .rateLimited(retryAfter: retryAfter(from: response.headers))
        case 503:
            return .overloaded
        default:
            return response.status >= 500
                ? .serverError(status: response.status)
                : .invalidRequest(diagnostic(from: response.body, redacting: secret))
        }
    }

    /// A short, controlled message from the provider's error envelope.
    ///
    /// Only the parsed `message` field, truncated — never the raw body, which could be
    /// arbitrarily large and could echo parts of the request. And it is a *value* inside
    /// a Zen error, not a type anything switches on.
    ///
    /// The run secret is removed before the length bound is applied. The value is used only
    /// for this in-memory mapping; it is not persisted or returned separately.
    static func diagnostic(from body: Data, redacting secret: SecretValue) -> String {
        guard let decoded = try? JSONDecoder().decode(DeepSeekErrorResponse.self, from: body),
              let message = decoded.error?.message,
              !message.isEmpty
        else {
            return "the provider rejected the request without a readable message"
        }
        var text = message

        // Primary defence: replace the actual secret used by this run.
        // Only the empty string is skipped: replacing an empty pattern would insert the
        // marker between characters. Any non-empty SecretValue, including whitespace-only
        // values, is still the run's credential.
        let raw = secret.revealed
        if !raw.isEmpty {
            text = text.replacingOccurrences(
                of: raw,
                with: HTTPRequest.redactedMarker
            )
        }

        // Secondary defence for a bearer token that is not this run's secret. It is applied
        // after exact replacement and before shortening, so a cut cannot leave a fragment
        // that no longer matches the full secret.
        text = Self.foldingBearerTokens(in: text)

        return String(text.prefix(200))
    }

    /// Folds every `Bearer <token>` shape back to `Bearer <redacted>`.
    ///
    /// The scheme must begin at a string boundary or after a non-word character. It must
    /// still be followed by at least one whitespace character and a non-empty token.
    private static func foldingBearerTokens(in message: String) -> String {
        var folded = ""
        var cursor = message.startIndex

        while let scheme = message.range(
            of: "bearer",
            options: .caseInsensitive,
            range: cursor..<message.endIndex
        ) {
            let afterScheme = scheme.upperBound

            if scheme.lowerBound != message.startIndex {
                let previousIndex = message.index(before: scheme.lowerBound)
                let previous = message[previousIndex]

                if previous.isLetter || previous.isNumber || previous == "_" {
                    folded += message[cursor..<afterScheme]
                    cursor = afterScheme
                    continue
                }
            }

            var tokenStart = afterScheme
            while tokenStart < message.endIndex, message[tokenStart].isWhitespace {
                tokenStart = message.index(after: tokenStart)
            }
            var tokenEnd = tokenStart
            while tokenEnd < message.endIndex, !message[tokenEnd].isWhitespace {
                tokenEnd = message.index(after: tokenEnd)
            }

            guard tokenStart > afterScheme, tokenEnd > tokenStart else {
                folded += message[cursor..<afterScheme]
                cursor = afterScheme
                continue
            }

            folded += message[cursor..<scheme.lowerBound]
            folded += message[scheme]
            folded += message[afterScheme..<tokenStart]
            folded += HTTPRequest.redactedMarker
            cursor = tokenEnd
        }

        return folded + message[cursor...]
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
            toolCalls: try Self.providerToolCalls(from: choice.message?.tool_calls),
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

    private static func providerToolCalls(
        from calls: [DeepSeekToolCall]?
    ) throws -> [ProviderToolCall] {
        try (calls ?? []).enumerated().map { index, call in
            guard
                let id = call.id,
                !id.isEmpty,
                let function = call.function,
                let name = function.name,
                !name.isEmpty
            else {
                throw ProviderError.malformedResponse(
                    "a response tool call was missing its id or function name"
                )
            }
            return ProviderToolCall(
                id: id,
                index: index,
                name: name,
                argumentsJSON: function.arguments ?? ""
            )
        }
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

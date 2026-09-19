import Foundation

/// The DeepSeek adapter.
///
/// Non-streaming only in this increment. Streaming is its own increment, and a transport
/// that could switch the response into a shape nothing here can parse is a switch worth
/// not having yet.
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
    let baseURL: URL

    init(transport: any HTTPTransport, baseURL: URL = DeepSeekProvider.defaultBaseURL) {
        self.transport = transport
        self.baseURL = baseURL
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
            credentials: credentials
        )

        guard let reference = instance.credentialReference else {
            // Unreachable: `validate` refuses a missing reference. Kept as a guard rather
            // than a force-unwrap so a future reordering of the checks fails visibly.
            throw ProviderError.credentialMissing
        }
        let secret = try Self.resolveSecret(reference, from: credentials)

        let httpRequest = try makeHTTPRequest(request, secret: secret)
        let httpResponse = try await transport.send(httpRequest)

        guard (200..<300).contains(httpResponse.status) else {
            throw Self.error(for: httpResponse)
        }
        return try Self.normalise(httpResponse.body)
    }

    // MARK: - Request

    private func makeHTTPRequest(_ request: ProviderChatRequest, secret: SecretValue) throws -> HTTPRequest {
        let body = DeepSeekChatRequest(
            model: request.modelID.rawValue,
            messages: request.messages.map {
                DeepSeekChatRequest.Message(role: $0.role.rawValue, content: $0.content)
            },
            stream: false
        )

        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(body)
        } catch {
            throw ProviderError.invalidRequest("the request body could not be encoded")
        }

        return HTTPRequest(
            method: .post,
            url: baseURL.appending(path: "chat/completions"),
            headers: [
                "Content-Type": "application/json",
                // The secret's only appearance outside the keychain, and it lives here
                // for the duration of one call. `HTTPRequest` redacts this header if
                // anything prints the request.
                "Authorization": "Bearer \(secret.revealed)",
                "Accept": "application/json",
            ],
            body: encoded
        )
    }

    // MARK: - Credential resolution

    /// The last moment the secret exists. Deliberately not stored, not cached, and not
    /// returned to any caller above this adapter.
    private static func resolveSecret(
        _ reference: CredentialReference,
        from credentials: any CredentialStoring
    ) throws -> SecretValue {
        do {
            guard let secret = try credentials.resolve(reference) else {
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
            }
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

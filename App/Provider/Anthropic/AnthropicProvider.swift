import Foundation

/// The Anthropic Messages API adapter. Runtime continues to own the conversation and
/// tool loop; this type translates the frozen request and response protocol.
struct AnthropicProvider: ModelProvider {
    static let defaultModelID = ModelID(rawValue: "claude-sonnet-5")
    static let defaultBaseURL = URL(string: "https://api.anthropic.com/v1")!
    static let defaultMaxOutputTokens = 4096

    private static let apiVersion = "2026-10-21"
    private static let capabilities: Set<ModelCapability> = [.text, .streaming, .tools]

    let id = ProviderID.anthropic
    let transport: any HTTPTransport
    let streamTimeouts: StreamTimeoutPolicy

    var adapterRevision: String { "anthropic-messages.v1" }
    var adapterPromptInstructions: String {
        "Use Anthropic Messages and preserve structured tool calls and their call IDs."
    }

    init(
        transport: any HTTPTransport,
        streamTimeouts: StreamTimeoutPolicy = .default
    ) {
        self.transport = transport
        self.streamTimeouts = streamTimeouts
    }

    static func resolvedEndpoint(for instance: ProviderInstance) -> URL {
        (instance.baseURL ?? defaultBaseURL).appending(path: "messages")
    }

    func knownModels(for instance: ProviderInstance) -> [ModelDescriptor] {
        [ModelDescriptor(
            id: Self.defaultModelID,
            providerInstanceID: instance.id,
            displayName: Self.defaultModelID.rawValue,
            capabilities: Self.capabilities
        )]
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
            resolvedEndpoint: Self.resolvedEndpoint(for: instance),
            maxOutputTokens: Self.defaultMaxOutputTokens
        )
    }

    func stream(
        _ request: ProviderChatRequest,
        seed: RequestConfigSeed,
        credentials: any CredentialStoring
    ) async throws -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        try Self.validate(request: request, against: seed)
        let secret = try Self.resolveSecret(seed.credentialBinding, from: credentials)
        let maxOutputTokens = try Self.maxOutputTokens(from: seed)
        let body = try AnthropicMessagesRequest.body(for: request, maxOutputTokens: maxOutputTokens)
        let httpRequest = HTTPRequest(
            method: .post,
            url: seed.endpoint,
            headers: [
                "Content-Type": "application/json",
                "Authorization": "Bearer \(secret.revealed)",
                "anthropic-version": Self.apiVersion,
                "Accept": "text/event-stream",
            ],
            body: body
        )

        let upstream: HTTPStream
        do {
            upstream = try await transport.stream(httpRequest)
        } catch {
            throw Self.providerError(from: error, deliveredOutput: false, redacting: secret)
        }
        return AnthropicMessagesStream.events(
            from: upstream,
            timeouts: streamTimeouts,
            redacting: secret
        )
    }

    private static func validate(request: ProviderChatRequest, against seed: RequestConfigSeed) throws {
        guard seed.modelID == Self.defaultModelID else {
            throw ProviderError.invalidRequest("the frozen Anthropic model is not supported by this adapter")
        }
        guard request.modelID == seed.modelID else {
            throw ProviderError.configurationMismatch(
                "the run was frozen against model \(seed.modelID.rawValue), not \(request.modelID.rawValue)"
            )
        }
        guard seed.thinkingEffort == nil else {
            throw ProviderError.invalidParameters("Anthropic thinking effort is fixed to none for this adapter")
        }
        _ = try Self.maxOutputTokens(from: seed)
    }

    private static func maxOutputTokens(from seed: RequestConfigSeed) throws -> Int {
        guard let limit = seed.maxOutputTokens, limit > 0 else {
            throw ProviderError.invalidParameters("the frozen Anthropic output-token limit is missing")
        }
        return limit
    }

    private static func resolveSecret(
        _ binding: CredentialBindingSnapshot,
        from credentials: any CredentialStoring
    ) throws -> SecretValue {
        do {
            guard let secret = try credentials.resolve(
                frozenReference: binding.reference,
                generation: binding.generation
            ) else {
                throw ProviderError.credentialMissingBeforeDispatch
            }
            return secret
        } catch let error as CredentialError {
            switch error {
            case .notFound:
                throw ProviderError.credentialMissingBeforeDispatch
            case .unavailable(_, let reason):
                throw ProviderError.credentialTemporarilyUnavailable(reason: reason)
            case .authenticationRequired:
                throw ProviderError.credentialRejectedBeforeDispatch
            case .alreadyExists:
                throw ProviderError.configurationMismatch("the credential store refused a read")
            case .bindingMoved(_, let frozenGeneration, let currentGeneration):
                throw ProviderError.configurationMismatch(
                    "the credential binding moved between validation and resolution " +
                    "(generation \(frozenGeneration) to \(currentGeneration))"
                )
            case .failed(_, let reason):
                throw ProviderError.credentialStorageFailed(reason: reason)
            }
        }
    }

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
            case .httpStatus(let response), .errorBodyTimeout(let response, _):
                return httpError(for: response, redacting: secret)
            case .inactivityTimeout(let elapsed):
                return .streamInactivityTimeout(after: elapsed, deliveredOutput: deliveredOutput)
            case .streamInterrupted(_, let reason):
                return .streamInterrupted(deliveredOutput: deliveredOutput, reason: reason)
            }
        case let parser as SSEParserError:
            switch parser {
            case .unterminatedStream:
                return .streamInterrupted(
                    deliveredOutput: deliveredOutput,
                    reason: "the Anthropic Messages stream ended without message_stop"
                )
            case .invalidUTF8:
                return .malformedResponse("an Anthropic Messages event was not valid UTF-8")
            case .malformedFrame(let reason):
                return .malformedResponse(reason)
            case .bufferLimitExceeded(let limit):
                return .malformedResponse("an Anthropic Messages event exceeded the \(limit)-byte reassembly bound")
            }
        case is CancellationError:
            return .cancelled
        case let provider as ProviderError:
            return provider
        default:
            return .transportFailure("the transport failed without a recognisable reason")
        }
    }

    static func eventFailure(
        code: String?,
        message: String?,
        deliveredOutput: Bool,
        redacting secret: SecretValue
    ) -> ProviderError {
        let detail = diagnostic(message, redacting: secret)
        if deliveredOutput {
            return .streamInterrupted(deliveredOutput: true, reason: detail)
        }
        switch code {
        case "authentication_error": return .credentialRejectedByHTTP401
        case "rate_limit_error": return .rateLimited(retryAfter: nil)
        case "overloaded_error": return .overloaded
        case "api_error": return .serverError(status: 500)
        case "billing_error": return .insufficientBalance
        default: return .invalidRequest(detail)
        }
    }

    private static func httpError(for response: HTTPResponse, redacting secret: SecretValue) -> ProviderError {
        switch response.status {
        case 400:
            return .invalidRequest(diagnostic(in: response.body, redacting: secret))
        case 401:
            return .credentialRejectedByHTTP401
        case 402:
            return .insufficientBalance
        case 422:
            return .invalidParameters(diagnostic(in: response.body, redacting: secret))
        case 429:
            return .rateLimited(retryAfter: retryAfter(in: response.headers))
        case 529:
            return .overloaded
        default:
            return response.status >= 500
                ? .serverError(status: response.status)
                : .invalidRequest(diagnostic(in: response.body, redacting: secret))
        }
    }

    private static func diagnostic(in body: Data, redacting secret: SecretValue) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let error = root["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return "the provider rejected the request without a readable message"
        }
        return diagnostic(message, redacting: secret)
    }

    private static func diagnostic(_ message: String?, redacting secret: SecretValue) -> String {
        guard var message, !message.isEmpty else {
            return "the provider rejected the request without a readable message"
        }
        if !secret.revealed.isEmpty {
            message = message.replacingOccurrences(of: secret.revealed, with: HTTPRequest.redactedMarker)
        }
        return String(message.prefix(200))
    }

    private static func retryAfter(in headers: [String: String]) -> TimeInterval? {
        guard let value = headers.first(where: {
            $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame
        })?.value, let seconds = TimeInterval(value) else { return nil }
        return max(0, seconds)
    }
}

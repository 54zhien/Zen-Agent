import Foundation

extension ProviderID {
    static let openAI = ProviderID(rawValue: "openai")

    var displayName: String {
        switch rawValue {
        case Self.deepSeek.rawValue: return "DeepSeek"
        case Self.openAI.rawValue: return "OpenAI"
        default: return rawValue
        }
    }
}

/// The OpenAI model API adapter. Zen owns the conversation and tool loop; this type
/// translates the frozen provider-neutral request to and from Responses.
struct OpenAIProvider: ModelProvider {
    static let defaultModelID = ModelID(rawValue: "gpt-6.1-terra")
    static let defaultBaseURL = URL(string: "https://api.openai.com/v1")!

    private static let capabilities: Set<ModelCapability> = [.text, .streaming, .tools]

    let id = ProviderID.openAI
    let transport: any HTTPTransport
    let streamTimeouts: StreamTimeoutPolicy

    var adapterRevision: String { "openai-responses.v1" }
    var adapterPromptInstructions: String {
        "Use OpenAI Responses and preserve structured function calls and their call IDs."
    }

    init(
        transport: any HTTPTransport,
        streamTimeouts: StreamTimeoutPolicy = .default
    ) {
        self.transport = transport
        self.streamTimeouts = streamTimeouts
    }

    static func resolvedEndpoint(for instance: ProviderInstance) -> URL {
        (instance.baseURL ?? defaultBaseURL).appending(path: "responses")
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
            resolvedEndpoint: Self.resolvedEndpoint(for: instance)
        )
    }

    func stream(
        _ request: ProviderChatRequest,
        seed: RequestConfigSeed,
        credentials: any CredentialStoring
    ) async throws -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        try Self.validate(request: request, against: seed)
        let secret = try Self.resolveSecret(seed.credentialBinding, from: credentials)
        let body = try OpenAIResponsesRequest.body(for: request)
        let httpRequest = HTTPRequest(
            method: .post,
            url: seed.endpoint,
            headers: [
                "Content-Type": "application/json",
                "Authorization": "Bearer \(secret.revealed)",
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
        return OpenAIResponsesStream.events(
            from: upstream,
            timeouts: streamTimeouts,
            redacting: secret
        )
    }

    private static func validate(request: ProviderChatRequest, against seed: RequestConfigSeed) throws {
        guard seed.modelID == Self.defaultModelID else {
            throw ProviderError.invalidRequest("the frozen OpenAI model is not supported by this adapter")
        }
        guard request.modelID == seed.modelID else {
            throw ProviderError.configurationMismatch(
                "the run was frozen against model \(seed.modelID.rawValue), not \(request.modelID.rawValue)"
            )
        }
        guard seed.thinkingEffort == nil else {
            throw ProviderError.invalidParameters("OpenAI Responses effort is fixed to none for this adapter")
        }
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
                    reason: "the Responses stream ended without its terminal response event"
                )
            case .invalidUTF8:
                return .malformedResponse("a Responses event was not valid UTF-8")
            case .malformedFrame(let reason):
                return .malformedResponse(reason)
            case .bufferLimitExceeded(let limit):
                return .malformedResponse("a Responses event exceeded the \(limit)-byte reassembly bound")
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
        if deliveredOutput {
            return .streamInterrupted(
                deliveredOutput: true,
                reason: diagnostic(message, redacting: secret)
            )
        }
        switch code {
        case "server_error": return .serverError(status: 500)
        case "server_is_overloaded", "server_overloaded": return .overloaded
        case "rate_limit_exceeded", "slow_down": return .rateLimited(retryAfter: nil)
        case "insufficient_quota", "credit_balance_exhausted", "organization_spend_limit_exceeded",
             "project_spend_limit_exceeded", "organization_usage_limit_exceeded", "usage_limit_exceeded":
            return .insufficientBalance
        default: return .invalidRequest(diagnostic(message, redacting: secret))
        }
    }

    private static func httpError(for response: HTTPResponse, redacting secret: SecretValue) -> ProviderError {
        switch response.status {
        case 401:
            return .credentialRejectedByHTTP401
        case 429:
            if errorCode(in: response.body) == "insufficient_quota" {
                return .insufficientBalance
            }
            return .rateLimited(retryAfter: retryAfter(in: response.headers))
        case 503:
            return .overloaded
        case 422:
            return .invalidParameters(diagnostic(in: response.body, redacting: secret))
        default:
            return response.status >= 500
                ? .serverError(status: response.status)
                : .invalidRequest(diagnostic(in: response.body, redacting: secret))
        }
    }

    private static func errorCode(in body: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let error = root["error"] as? [String: Any] else { return nil }
        return error["code"] as? String
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
        guard let value = headers.first(where: { $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame })?.value,
              let seconds = TimeInterval(value) else { return nil }
        return max(0, seconds)
    }
}

import Foundation

struct GLMProvider: ModelProvider {
    static let defaultModelID = ModelID(rawValue: "glm-5.3")
    static let defaultBaseURL = URL(string: "https://open.bigmodel.cn/api/paas/v4")!

    private static let capabilities: Set<ModelCapability> = [.text, .streaming, .reasoning, .tools]
    private static let thinkingEfforts: Set<ThinkingEffort> = [.low, .high, .max]

    let id = ProviderID.glm
    let transport: any HTTPTransport
    let streamTimeouts: StreamTimeoutPolicy

    var adapterRevision: String { "glm-chat-completions.v1" }
    var adapterPromptInstructions: String {
        "Use GLM Chat Completions and preserve reasoning content and structured tool calls."
    }

    init(
        transport: any HTTPTransport,
        streamTimeouts: StreamTimeoutPolicy = .default
    ) {
        self.transport = transport
        self.streamTimeouts = streamTimeouts
    }

    static func resolvedEndpoint(for instance: ProviderInstance) -> URL {
        (instance.baseURL ?? defaultBaseURL).appending(path: "chat/completions")
    }

    func knownModels(for instance: ProviderInstance) -> [ModelDescriptor] {
        [ModelDescriptor(
            id: Self.defaultModelID,
            providerInstanceID: instance.id,
            displayName: Self.defaultModelID.rawValue,
            capabilities: Self.capabilities,
            thinkingEfforts: Self.thinkingEfforts
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
            throw ProviderError.invalidRequest("unknown GLM model \(modelID.rawValue)")
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
        guard seed.modelID == Self.defaultModelID else {
            throw ProviderError.invalidRequest("the frozen GLM model is not supported by this adapter")
        }
        guard request.modelID == seed.modelID else {
            throw ProviderError.configurationMismatch(
                "the run was frozen against model \(seed.modelID.rawValue), not \(request.modelID.rawValue)"
            )
        }
        if let effort = seed.thinkingEffort, !Self.thinkingEfforts.contains(effort) {
            throw ProviderError.invalidParameters("Frozen thinking effort is not supported by GLM-5.3")
        }

        let secret = try Self.resolveSecret(seed.credentialBinding, from: credentials)
        let body: Data
        do {
            body = try GLMChatCompletionRequest.body(for: request, thinkingEffort: seed.thinkingEffort)
        } catch {
            throw ProviderError.invalidRequest("the GLM request body could not be encoded")
        }
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
        return GLMChatCompletionStream.events(
            from: upstream,
            timeouts: streamTimeouts,
            redacting: secret
        )
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
                return Self.error(for: response, redacting: secret)
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
                    reason: "the GLM stream ended without its terminator"
                )
            case .invalidUTF8:
                return .malformedResponse("a GLM stream event was not valid UTF-8")
            case .malformedFrame(let reason):
                return .malformedResponse(reason)
            case .bufferLimitExceeded(let limit):
                return .malformedResponse("a GLM stream event exceeded the \(limit)-byte reassembly bound")
            }
        case is CancellationError:
            return .cancelled
        case let provider as ProviderError:
            return provider
        default:
            return .transportFailure("the transport failed without a recognisable reason")
        }
    }

    private static func error(
        for response: HTTPResponse,
        redacting secret: SecretValue
    ) -> ProviderError {
        switch response.status {
        case 401:
            return .credentialRejectedByHTTP401
        case 402:
            return .insufficientBalance
        case 422:
            return .invalidParameters(diagnostic(in: response.body, redacting: secret))
        case 429:
            return .rateLimited(retryAfter: retryAfter(in: response.headers))
        case 503:
            return .overloaded
        default:
            return response.status >= 500
                ? .serverError(status: response.status)
                : .invalidRequest(diagnostic(in: response.body, redacting: secret))
        }
    }

    private static func diagnostic(in body: Data, redacting secret: SecretValue) -> String {
        guard
            let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let error = root["error"] as? [String: Any],
            let message = error["message"] as? String,
            !message.isEmpty
        else {
            return "the provider rejected the request without a readable message"
        }
        let redacted = secret.revealed.isEmpty
            ? message
            : message.replacingOccurrences(of: secret.revealed, with: HTTPRequest.redactedMarker)
        return String(redacted.prefix(200))
    }

    private static func retryAfter(in headers: [String: String]) -> TimeInterval? {
        guard let value = headers.first(where: {
            $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame
        })?.value else { return nil }
        return TimeInterval(value)
    }
}
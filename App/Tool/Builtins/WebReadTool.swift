import Foundation

struct WebReadTool: ToolExecutable {
    static let toolID = "web_read"

    let descriptor: ToolDescriptor
    private let transport: any HTTPTransport

    init(transport: any HTTPTransport) {
        self.transport = transport
        self.descriptor = ToolDescriptor(
            id: Self.toolID,
            displayName: "Read Web Page",
            description: "Reads bounded text from one explicit anonymous HTTPS page URL after approval. Returns text and its source URL.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "url": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("url")]),
                "additionalProperties": .bool(false),
            ]),
            revision: "1",
            sideEffect: .none,
            approvalRequirement: .required,
            actions: [ToolPolicyActionMetadata(
                toolID: Self.toolID,
                actionID: Self.toolID,
                descriptorRevision: "1",
                risk: .high,
                allowsAutomaticApproval: false,
                allowsConversationGrant: false,
                resourceRequirement: .target,
                egressRequirement: .webOriginRequiringApproval
            )]
        )
    }

    func prepare(callID: String, argumentsJSON: String) throws -> ToolExecutionIntent {
        _ = callID
        throw ToolIntentFailure.preparationFailed
    }

    func prepare(
        callID: String,
        argumentsJSON: String,
        context: ToolPreparationContext
    ) throws -> ToolExecutionIntent {
        _ = callID
        let supplied = try ToolArgumentJSON.object(from: argumentsJSON)
        guard supplied.count == 1, let rawURL = supplied["url"] as? String,
              let url = Self.normalizedPageURL(rawURL),
              let origin = HTTPOriginIdentity.from(url) else {
            throw ToolIntentFailure.invalidArguments
        }
        let normalizedArguments = try ToolArgumentJSON.normalizedObject(["url": url.absoluteString])
        let destination = ToolDestinationScope.webOrigin(
            pageOrigin: origin,
            providerInstanceID: context.requestConfigSeed.providerInstanceID.rawValue,
            providerEndpointIdentity: context.requestConfigSeed.endpoint.absoluteString
        )
        return try ToolIntentCodec.freeze(
            descriptor: descriptor,
            actionID: Self.toolID,
            normalizedArgumentsJSON: normalizedArguments,
            resource: .target(Self.sourceURL(for: url)),
            destination: destination,
            approvalDisclosure: ToolApprovalDisclosure(
                toolDisplayName: descriptor.displayName,
                action: "匿名读取 HTTPS 网页正文",
                targetDescription: Self.sourceURL(for: url),
                keyImpact: "网页来源：\(origin)。提取的正文与来源将发送给冻结的 Provider \(context.requestConfigSeed.providerInstanceID.rawValue) · \(context.requestConfigSeed.endpoint.absoluteString)。"
            )
        )
    }

    func validateDependencies(_ intent: ToolExecutionIntent, context: ToolPreparationContext) throws {
        try validateDependencies(intent)
        guard case .webOrigin(_, let providerID, let endpoint) = intent.destinationScope,
              ToolPolicyIdentity.equals(providerID, context.requestConfigSeed.providerInstanceID.rawValue),
              ToolPolicyIdentity.equals(endpoint, context.requestConfigSeed.endpoint.absoluteString) else {
            throw ToolIntentFailure.dependenciesChanged
        }
    }

    func validateDependencies(_ intent: ToolExecutionIntent) throws {
        try ToolIntentCodec.validate(intent, descriptor: descriptor)
        guard let url = Self.pageURL(in: intent),
              case .target(let target) = intent.resourceScope,
              case .webOrigin(let pageOrigin, _, _) = intent.destinationScope,
              let origin = HTTPOriginIdentity.from(url),
              ToolPolicyIdentity.equals(target, Self.sourceURL(for: url)),
              ToolPolicyIdentity.equals(pageOrigin, origin) else {
            throw ToolIntentFailure.invalidScope
        }
    }

    func execute(_ intent: ToolExecutionIntent, idempotencyKey: String) async throws -> ToolExecutionResult {
        _ = idempotencyKey
        try validateDependencies(intent)
        guard let url = Self.pageURL(in: intent),
              let origin = HTTPOriginIdentity.from(url) else { throw ToolIntentFailure.invalidScope }

        let request = HTTPRequest(
            method: .get,
            url: url,
            headers: ["Accept": "text/html, application/xhtml+xml, text/plain"],
            redirectPolicy: .sameOrigin,
            maximumResponseBytes: ToolResultGuard.maximumUTF8Bytes
        )
        let stream: HTTPStream
        do {
            stream = try await transport.stream(request)
        } catch HTTPTransportError.httpStatus(let response) {
            if let refusal = response.redirectRefusal {
                let reason = switch refusal.reason {
                case .crossOrigin: "cross-origin redirect"
                case .credentials: "credential-bearing redirect"
                case .invalidOrigin: "redirect with an invalid origin"
                }
                return ToolExecutionResult(content: "Web read refused a \(reason) from \(refusal.sourceOrigin) to \(refusal.destinationOrigin).")
            }
            return ToolExecutionResult(
                content: "Web read failed with HTTP status \(response.status) at \(origin).",
                kind: .error,
                failure: .executionFailed
            )
        }
        defer { stream.cancel() }

        guard let responseHead = stream.responseHead,
              (200..<300).contains(responseHead.status),
              HTTPOriginIdentity.from(responseHead.finalURL) == origin else {
            return ToolExecutionResult.failure(.executionFailed)
        }
        var body = Data()
        body.reserveCapacity(ToolResultGuard.maximumUTF8Bytes)
        do {
            for try await chunk in stream.body {
                try Task.checkCancellation()
                guard chunk.count <= ToolResultGuard.maximumUTF8Bytes - body.count else {
                    return ToolExecutionResult.failure(.resultTooLarge)
                }
                body.append(chunk)
            }
        } catch HTTPTransportError.streamInterrupted(_, let reason)
            where reason == HTTPTransportError.responseBodyLimitExceededReason {
            return ToolExecutionResult.failure(.resultTooLarge)
        }

        let contentType = responseHead.headers.first {
            $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame
        }?.value
        guard let text = WebPageTextExtractor.extract(body, contentType: contentType) else {
            return ToolExecutionResult.failure(.invalidResult)
        }
        let source = Self.sourceURL(for: responseHead.finalURL)
        return Self.result(text: text, source: source)
    }

    private static func pageURL(in intent: ToolExecutionIntent) -> URL? {
        guard let object = try? ToolArgumentJSON.object(from: intent.normalizedArgumentsJSON),
              object.count == 1, let rawURL = object["url"] as? String else { return nil }
        return normalizedPageURL(rawURL)
    }

    private static func normalizedPageURL(_ rawURL: String) -> URL? {
        guard rawURL.utf8.count <= ToolResultGuard.maximumUTF8Bytes,
              let url = URL(string: rawURL),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        components.scheme = "https"
        components.host = host.lowercased()
        components.fragment = nil
        return components.url
    }

    private static func sourceURL(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "https://<unavailable>"
        }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.string ?? "https://<unavailable>"
    }

    private static func result(text: String, source: String) -> ToolExecutionResult {
        let prefix = "Source: \(source)\n\n"
        let remaining = ToolResultGuard.maximumUTF8Bytes - prefix.utf8.count
        guard remaining >= 0 else { return .failure(.resultTooLarge) }
        var boundedText = String.UnicodeScalarView()
        var used = 0
        for scalar in text.unicodeScalars {
            let scalarBytes = String(scalar).utf8.count
            guard used + scalarBytes <= remaining else { break }
            boundedText.append(scalar)
            used += scalarBytes
        }
        return ToolExecutionResult(content: prefix + String(boundedText))
    }
}

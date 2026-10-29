import Foundation

private final class MCPConnectionLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var requests: [String: Task<MCPJSONRPCResponse, Error>] = [:]

    func begin(_ requestID: String) -> Bool {
        lock.withLock { !closed && requests[requestID] == nil }
    }

    func isOpen() -> Bool { lock.withLock { !closed } }

    func install(_ task: Task<MCPJSONRPCResponse, Error>, for requestID: String) {
        let shouldCancel = lock.withLock {
            guard !closed else { return true }
            requests[requestID] = task
            return false
        }
        if shouldCancel { task.cancel() }
    }

    func finish(_ requestID: String) { _ = lock.withLock { requests.removeValue(forKey: requestID) } }

    func close() {
        let active = lock.withLock { () -> [Task<MCPJSONRPCResponse, Error>] in
            closed = true
            let active = Array(requests.values)
            requests.removeAll()
            return active
        }
        active.forEach { $0.cancel() }
    }
}

enum MCPProtocolMode: Sendable, Equatable {
    case modern(version: String)
    case legacy(version: String, sessionID: String?)
}

struct MCPConnection: Sendable {
    let server: MCPServer
    let endpoint: URL
    let mode: MCPProtocolMode
    let authentication: MCPAuthenticationResolver?
    let serverInfo: MCPServerInfo?
    let capabilities: MCPServerCapabilities
    let tools: [MCPToolDefinition]
    let resources: [MCPResourceDefinition]
    let prompts: [MCPPromptDefinition]
    var endpointIdentity: String { MCPServerEndpointIdentity.digest(endpoint) }
    var authenticationIdentity: String? { authentication?.identity }
    private let transport: any HTTPTransport
    private let lifecycle = MCPConnectionLifecycle()

    init(
        server: MCPServer,
        endpoint: URL,
        mode: MCPProtocolMode,
        authentication: MCPAuthenticationResolver?,
        serverInfo: MCPServerInfo?,
        capabilities: MCPServerCapabilities,
        tools: [MCPToolDefinition],
        resources: [MCPResourceDefinition],
        prompts: [MCPPromptDefinition],
        transport: any HTTPTransport
    ) {
        self.server = server
        self.endpoint = endpoint
        self.mode = mode
        self.authentication = authentication
        self.serverInfo = serverInfo
        self.capabilities = capabilities
        self.tools = tools
        self.resources = resources
        self.prompts = prompts
        self.transport = transport
    }

    func disconnect() async { lifecycle.close() }

    func isAvailable() -> Bool { lifecycle.isOpen() }

    func callTool(_ tool: MCPToolDefinition, arguments: [String: JSONValue]) async throws -> MCPToolCallResult {
        let requestID = UUID().uuidString
        guard lifecycle.begin(requestID) else { throw MCPClientError.connectionUnavailable }
        let mode = self.mode
        let endpoint = self.endpoint
        let authentication = self.authentication
        let transport = self.transport
        let task = Task<MCPJSONRPCResponse, Error> {
            try await Self.performToolCall(
                tool,
                arguments: arguments,
                requestID: requestID,
                mode: mode,
                endpoint: endpoint,
                authentication: authentication,
                transport: transport
            )
        }
        lifecycle.install(task, for: requestID)
        do {
            let response = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            lifecycle.finish(requestID)
            let result = try MCPJSONRPCDecoder.requireResult(response)
            let decoded = try MCPJSONRPCDecoder.decode(MCPToolCallPayload.self, from: result)
            return MCPToolCallResult(
                content: decoded.content,
                structuredContent: decoded.structuredContent,
                isError: decoded.isError ?? false
            )
        } catch {
            lifecycle.finish(requestID)
            if case .legacy(_, let sessionID) = mode,
               sessionID != nil,
               let failure = error as? MCPHTTPStatusFailure,
               failure.response.status == 404 {
                lifecycle.close()
                throw MCPClientError.connectionUnavailable
            }
            throw error
        }
    }

    private static func performToolCall(
        _ tool: MCPToolDefinition,
        arguments: [String: JSONValue],
        requestID: String,
        mode: MCPProtocolMode,
        endpoint: URL,
        authentication: MCPAuthenticationResolver?,
        transport: any HTTPTransport
    ) async throws -> MCPJSONRPCResponse {
        let params: [String: JSONValue] = [
            "name": .string(tool.name),
            "arguments": .object(arguments)
        ]
        let request: HTTPRequest
        switch mode {
        case .modern:
            request = try MCPRequestBuilder.modern(
                endpoint: endpoint,
                method: "tools/call",
                id: requestID,
                params: params,
                bearerToken: try authentication?.resolve(),
                parameterHeaders: MCPRequestBuilder.parameterHeaders(
                    arguments: arguments,
                    inputSchema: tool.inputSchema
                )
            )
        case .legacy(let version, let sessionID):
            request = try MCPRequestBuilder.legacy(
                endpoint: endpoint,
                method: "tools/call",
                id: requestID,
                params: params,
                protocolVersion: version,
                sessionID: sessionID,
                bearerToken: try authentication?.resolve()
            )
        }
        return try await MCPClient.request(
            request,
            requestID: requestID,
            transport: transport,
            onCancelled: {
                guard case .legacy(let version, let sessionID) = mode else { return }
                await MCPClient.sendCancellation(
                    requestID: requestID,
                    endpoint: endpoint,
                    protocolVersion: version,
                    sessionID: sessionID,
                    authentication: authentication,
                    transport: transport
                )
            }
        )
    }
}

private struct MCPToolCallPayload: Decodable {
    let content: [JSONValue]
    let structuredContent: JSONValue?
    let isError: Bool?
}

private struct MCPHTTPStatusFailure: Error {
    let response: HTTPResponse
}

struct MCPClient: Sendable {
    let transport: any HTTPTransport
    let authentication: MCPAuthenticationResolver?

    init(transport: any HTTPTransport, authentication: MCPAuthenticationResolver? = nil) {
        self.transport = transport
        self.authentication = authentication
    }

    func connect(server: MCPServer) async throws -> MCPConnection {
        guard let endpoint = URL(string: server.endpoint),
              endpoint.host != nil,
              endpoint.user == nil,
              endpoint.password == nil,
              ["https", "http"].contains(endpoint.scheme?.lowercased() ?? "") else {
            throw MCPClientError.invalidEndpoint
        }

        let discoveryID = UUID().uuidString
        let discoveryRequest = try MCPRequestBuilder.modern(
            endpoint: endpoint,
            method: "server/discover",
            id: discoveryID,
            bearerToken: try authentication?.resolve()
        )
        let discoveryResponse: MCPJSONRPCResponse
        do {
            discoveryResponse = try await Self.request(
                discoveryRequest,
                requestID: discoveryID,
                transport: transport
            )
        } catch let failure as MCPHTTPStatusFailure {
            let status = failure.response.status
            if status == 401 || status == 403 { throw MCPClientError.authenticationRequired }
            guard (400..<500).contains(status) else { throw MCPClientError.httpStatus(status) }
            if let error = MCPJSONRPCDecoder.errorResponse(from: failure.response) {
                if error.code == -32022 {
                    throw MCPClientError.unsupportedProtocol(Self.supportedVersions(from: error))
                }
                if [-32021, -32020].contains(error.code) {
                    throw MCPClientError.rpcError(code: error.code, message: error.message)
                }
            }
            return try await connectLegacy(server: server, endpoint: endpoint)
        }

        if let error = discoveryResponse.error {
            if error.code == -32022 {
                throw MCPClientError.unsupportedProtocol(Self.supportedVersions(from: error))
            }
            throw MCPClientError.rpcError(code: error.code, message: error.message)
        }

        let discovery = try MCPJSONRPCDecoder.decode(
            MCPDiscoverResult.self,
            from: MCPJSONRPCDecoder.requireResult(discoveryResponse)
        )
        guard discovery.supportedVersions.contains(MCPProtocolVersion.modern) else {
            throw MCPClientError.unsupportedProtocol(discovery.supportedVersions)
        }
        let catalog = try await discoverCapabilities(
            endpoint: endpoint,
            mode: .modern(version: MCPProtocolVersion.modern),
            capabilities: discovery.capabilities
        )
        return MCPConnection(
            server: server,
            endpoint: endpoint,
            mode: .modern(version: MCPProtocolVersion.modern),
            authentication: authentication,
            serverInfo: discovery.meta?.serverInfo,
            capabilities: discovery.capabilities,
            tools: catalog.tools,
            resources: catalog.resources,
            prompts: catalog.prompts,
            transport: transport
        )
    }

    private func connectLegacy(server: MCPServer, endpoint: URL) async throws -> MCPConnection {
        let initializeID = UUID().uuidString
        let initializeRequest = try MCPRequestBuilder.legacy(
            endpoint: endpoint,
            method: "initialize",
            id: initializeID,
            params: [
                "protocolVersion": .string(MCPProtocolVersion.legacy),
                "capabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string("Zen Agent"),
                    "version": .string(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0")
                ])
            ],
            bearerToken: try authentication?.resolve()
        )
        let initializeResponse = try await transport.send(initializeRequest)
        if initializeResponse.status == 401 || initializeResponse.status == 403 {
            throw MCPClientError.authenticationRequired
        }
        guard (200..<300).contains(initializeResponse.status) else {
            throw MCPClientError.httpStatus(initializeResponse.status)
        }
        let response = try MCPJSONRPCDecoder.response(from: initializeResponse.body, requestID: initializeID)
        let result = try MCPJSONRPCDecoder.decode(
            MCPLegacyInitializeResult.self,
            from: MCPJSONRPCDecoder.requireResult(response)
        )
        guard result.protocolVersion == MCPProtocolVersion.legacy else {
            throw MCPClientError.unsupportedProtocol([result.protocolVersion])
        }
        let sessionID = Self.header("Mcp-Session-Id", in: initializeResponse.headers)
        let mode = MCPProtocolMode.legacy(version: result.protocolVersion, sessionID: sessionID)
        let initialized = try MCPRequestBuilder.legacy(
            endpoint: endpoint,
            method: "notifications/initialized",
            id: nil,
            protocolVersion: result.protocolVersion,
            sessionID: sessionID,
            bearerToken: try authentication?.resolve()
        )
        let initializedResponse = try await transport.send(initialized)
        guard (200..<300).contains(initializedResponse.status) else {
            if initializedResponse.status == 401 || initializedResponse.status == 403 {
                throw MCPClientError.authenticationRequired
            }
            throw MCPClientError.httpStatus(initializedResponse.status)
        }

        let catalog = try await discoverCapabilities(
            endpoint: endpoint,
            mode: mode,
            capabilities: result.capabilities
        )
        return MCPConnection(
            server: server,
            endpoint: endpoint,
            mode: mode,
            authentication: authentication,
            serverInfo: result.serverInfo,
            capabilities: result.capabilities,
            tools: catalog.tools,
            resources: catalog.resources,
            prompts: catalog.prompts,
            transport: transport
        )
    }

    private func discoverCapabilities(
        endpoint: URL,
        mode: MCPProtocolMode,
        capabilities: MCPServerCapabilities
    ) async throws -> (tools: [MCPToolDefinition], resources: [MCPResourceDefinition], prompts: [MCPPromptDefinition]) {
        var tools: [MCPToolDefinition] = []
        var resources: [MCPResourceDefinition] = []
        var prompts: [MCPPromptDefinition] = []

        if capabilities.tools != nil {
            tools = try await listPages(
                method: "tools/list",
                endpoint: endpoint,
                mode: mode,
                as: MCPToolsListPage.self
            ).flatMap(\.tools)
        }
        if capabilities.resources != nil {
            resources = try await listPages(
                method: "resources/list",
                endpoint: endpoint,
                mode: mode,
                as: MCPResourcesListPage.self
            ).flatMap(\.resources)
        }
        if capabilities.prompts != nil {
            prompts = try await listPages(
                method: "prompts/list",
                endpoint: endpoint,
                mode: mode,
                as: MCPPromptsListPage.self
            ).flatMap(\.prompts)
        }
        return (tools, resources, prompts)
    }

    private func listPages<Page: Decodable>(
        method: String,
        endpoint: URL,
        mode: MCPProtocolMode,
        as pageType: Page.Type
    ) async throws -> [Page] {
        var pages: [Page] = []
        var cursor: String?
        repeat {
            var params: [String: JSONValue] = [:]
            if let cursor { params["cursor"] = .string(cursor) }
            let requestID = UUID().uuidString
            let request: HTTPRequest
            switch mode {
            case .modern:
                request = try MCPRequestBuilder.modern(
                    endpoint: endpoint,
                    method: method,
                    id: requestID,
                    params: params,
                    bearerToken: try authentication?.resolve()
                )
            case .legacy(let version, let sessionID):
                request = try MCPRequestBuilder.legacy(
                    endpoint: endpoint,
                    method: method,
                    id: requestID,
                    params: params,
                    protocolVersion: version,
                    sessionID: sessionID,
                    bearerToken: try authentication?.resolve()
                )
            }
            let response = try await Self.request(
                request,
                requestID: requestID,
                transport: transport,
                onCancelled: {
                    guard case .legacy(let version, let sessionID) = mode else { return }
                    await Self.sendCancellation(
                        requestID: requestID,
                        endpoint: endpoint,
                        protocolVersion: version,
                        sessionID: sessionID,
                        authentication: authentication,
                        transport: transport
                    )
                }
            )
            let result = try MCPJSONRPCDecoder.object(MCPJSONRPCDecoder.requireResult(response))
            let encodedPage = try JSONEncoder().encode(JSONValue.object(result))
            let page = try JSONDecoder().decode(pageType, from: encodedPage)
            pages.append(page)
            cursor = result["nextCursor"].flatMap {
                if case .string(let value) = $0 { return value }
                return nil
            }
        } while cursor != nil
        return pages
    }

    static func request(
        _ request: HTTPRequest,
        requestID: String,
        transport: any HTTPTransport,
        onCancelled: (@Sendable () async -> Void)? = nil
    ) async throws -> MCPJSONRPCResponse {
        let stream: HTTPStream
        do {
            stream = try await transport.stream(request)
        } catch let error as HTTPTransportError {
            if case .httpStatus(let response) = error {
                throw MCPHTTPStatusFailure(response: response)
            }
            if case .cancelled = error { throw CancellationError() }
            throw error
        }
        defer { stream.cancel() }
        do {
            let response = try await withTaskCancellationHandler {
                var body = Data()
                for try await chunk in stream.body {
                    body.append(chunk)
                }
                try Task.checkCancellation()
                return try MCPJSONRPCDecoder.response(from: body, requestID: requestID)
            } onCancel: {
                stream.cancel()
            }
            return response
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? HTTPTransportError) == .cancelled {
                if let onCancelled {
                    await Task.detached { await onCancelled() }.value
                }
                throw CancellationError()
            }
            throw error
        }
    }

    static func sendCancellation(
        requestID: String,
        endpoint: URL,
        protocolVersion: String,
        sessionID: String?,
        authentication: MCPAuthenticationResolver?,
        transport: any HTTPTransport
    ) async {
        guard let request = try? MCPRequestBuilder.legacy(
            endpoint: endpoint,
            method: "notifications/cancelled",
            id: nil,
            params: [
                "requestId": .string(requestID),
                "reason": .string("Operation cancelled")
            ],
            protocolVersion: protocolVersion,
            sessionID: sessionID,
            bearerToken: try? authentication?.resolve()
        ) else { return }
        do {
            _ = try await transport.send(request)
        } catch {
            return
        }
    }

    private static func supportedVersions(from error: MCPJSONRPCError) -> [String] {
        guard case .object(let data) = error.data,
              case .array(let values)? = data["supported"] else { return [] }
        return values.compactMap {
            if case .string(let version) = $0 { return version }
            return nil
        }
    }

    private static func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

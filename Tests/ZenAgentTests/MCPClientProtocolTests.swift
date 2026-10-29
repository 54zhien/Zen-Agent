import Foundation
import Testing

@testable import ZenAgent

@Suite("MCP Streamable HTTP negotiation")
struct MCPClientProtocolTests {
    @Test("an endpoint without modern discovery uses the 2025 initialize lifecycle")
    func legacyStreamableHTTPHandshake() async throws {
        let transport = LegacyMCPFixtureTransport()
        let server = MCPServer(
            id: "mcp-server-fixture",
            displayName: "Legacy fixture",
            endpoint: "https://mcp.example.test/mcp",
            enabled: true,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )

        let connection = try await MCPClient(transport: transport).connect(server: server)

        #expect(connection.mode == .legacy(version: MCPProtocolVersion.legacy, sessionID: "fixture-session"))
        #expect(connection.tools.map(\.name) == ["lookup"])
        #expect(transport.methods == ["server/discover", "initialize", "notifications/initialized", "tools/list"])

        let requests = transport.requests
        #expect(requests[0].headers["MCP-Protocol-Version"] == MCPProtocolVersion.modern)
        #expect(requests[1].headers["MCP-Protocol-Version"] == nil)
        #expect(requests[2].headers["MCP-Protocol-Version"] == MCPProtocolVersion.legacy)
        #expect(requests[2].headers["Mcp-Session-Id"] == "fixture-session")
        #expect(requests[3].headers["MCP-Protocol-Version"] == MCPProtocolVersion.legacy)
        #expect(requests[3].headers["Mcp-Session-Id"] == "fixture-session")

        let initialized = try #require(requests[2].body.flatMap(jsonObject))
        #expect(initialized["id"] == nil)
        let listRequest = try #require(requests[3].body.flatMap(jsonObject))
        let params = try #require(listRequest["params"] as? [String: Any])
        #expect(params["_meta"] == nil)
    }

    @Test("a legacy session 404 closes the old connection and reconnect creates a new session")
    func expiredLegacySessionIsNotReplayed() async throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let serverRegistry = MCPServerRegistry(store: store)
        let server = try serverRegistry.create(
            displayName: "Legacy fixture",
            endpoint: "https://mcp.example.test/mcp"
        )
        _ = try serverRegistry.setEnabled(id: server.id, enabled: true)
        let transport = LegacyMCPFixtureTransport()
        let runtime = MCPServerRuntime(
            registry: serverRegistry,
            store: store,
            credentials: CredentialStore(
                secrets: InMemorySecretBackend(),
                metadataRepository: InMemoryCredentialMetadataRepository()
            ),
            transport: transport
        )

        let initial = try await runtime.connect(serverID: server.id)
        let registry = try await runtime.unifiedToolRegistry(base: .empty)
        let executable = try #require(registry.executor(id: initial.toolDescriptors[0].id) as? MCPToolExecutable)
        let intent = try executable.prepare(callID: "expired-session-call", argumentsJSON: #"{"query":"hello"}"#)

        var callFailure: Error?
        do {
            _ = try await executable.execute(intent, idempotencyKey: "expired-session-call")
        } catch {
            callFailure = error
        }
        #expect(callFailure as? MCPClientError == .connectionUnavailable)
        #expect(!executable.connection.isAvailable())

        #expect(try await runtime.unifiedToolRegistry(base: .empty).descriptors.isEmpty)
        #expect(await runtime.connectionSnapshot(serverID: server.id)?.state == .disconnected)

        await runtime.reconnectEnabledServers()
        #expect(try await runtime.unifiedToolRegistry(base: .empty).descriptors.count == 1)
        #expect(transport.methods.filter { $0 == "initialize" }.count == 2)
        #expect(transport.methods.filter { $0 == "tools/call" }.count == 1)
    }
}

private final class LegacyMCPFixtureTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [HTTPRequest] = []

    var requests: [HTTPRequest] { lock.withLock { recorded } }

    var methods: [String] {
        requests.compactMap { request in
            guard let body = request.body, let object = jsonObject(body) else { return nil }
            return object["method"] as? String
        }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.withLock { recorded.append(request) }
        guard let body = request.body, let object = jsonObject(body),
              let method = object["method"] as? String else {
            throw MCPClientError.invalidResponse
        }
        switch method {
        case "initialize":
            let id = try #require(object["id"] as? String)
            return HTTPResponse(
                status: 200,
                headers: ["Mcp-Session-Id": "fixture-session"],
                json: #"{"jsonrpc":"2.0","id":"\#(id)","result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"Legacy fixture","version":"1"}}}"#
            )
        case "notifications/initialized":
            return HTTPResponse(status: 202)
        default:
            throw MCPClientError.invalidResponse
        }
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        lock.withLock { recorded.append(request) }
        guard let body = request.body, let object = jsonObject(body),
              let method = object["method"] as? String else {
            throw MCPClientError.invalidResponse
        }
        if method == "server/discover" {
            throw HTTPTransportError.httpStatus(HTTPResponse(status: 404))
        }
        if method == "tools/call" {
            throw HTTPTransportError.httpStatus(HTTPResponse(status: 404))
        }
        guard method == "tools/list", let id = object["id"] as? String else {
            throw MCPClientError.invalidResponse
        }
        let response = #"{"jsonrpc":"2.0","id":"\#(id)","result":{"tools":[{"name":"lookup","inputSchema":{"type":"object","properties":{}}}]}}"#
        let data = Data(response.utf8)
        return HTTPStream(
            body: AsyncThrowingStream { continuation in
                continuation.yield(data)
                continuation.finish()
            },
            cancel: {}
        )
    }
}

private func jsonObject(_ data: Data) -> [String: Any]? {
    try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

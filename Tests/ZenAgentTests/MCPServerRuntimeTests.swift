import Foundation
import Testing

@testable import ZenAgent

@Suite("MCP server runtime")
struct MCPServerRuntimeTests {
    @Test("connected Tools enter the unified registry and remain a read-only catalog after disconnect")
    func connectedToolsUseTheUnifiedRegistry() async throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let serverRegistry = MCPServerRegistry(store: store)
        let server = try serverRegistry.create(displayName: "Local tools", endpoint: "https://mcp.example.test/mcp")
        _ = try serverRegistry.setEnabled(id: server.id, enabled: true)
        let transport = MCPFixtureTransport()
        let credentials = CredentialStore(secrets: InMemorySecretBackend(),
                                          metadataRepository: InMemoryCredentialMetadataRepository())
        let runtime = MCPServerRuntime(registry: serverRegistry, store: store,
                                       credentials: credentials, transport: transport)

        let connected = try await runtime.connect(serverID: server.id)
        #expect(connected.state == .connected)
        #expect(connected.serverInfo?.name == "Fixture MCP")
        #expect(connected.tools.map(\.name) == ["lookup"])

        let unified = try await runtime.unifiedToolRegistry(base: .empty)
        let descriptor = try #require(unified.descriptors.first)
        #expect(descriptor.id == MCPToolExecutable.toolID(serverID: server.id, toolName: "lookup"))
        #expect(descriptor.actions.first?.egressRequirement == .mcpServerRequiringApproval)
        #expect(descriptor.actions.first?.allowsAutomaticApproval == false)

        let executable = try #require(unified.executor(id: descriptor.id))
        let intent = try executable.prepare(callID: "call-1", argumentsJSON: #"{"query":"hello"}"#)
        let result = try await executable.execute(intent, idempotencyKey: "call-1")
        #expect(result.content == "fixture result")
        #expect(transport.methods == ["server/discover", "tools/list", "tools/call"])

        let disconnected = await runtime.disconnect(serverID: server.id)
        #expect(disconnected.state == .disconnected)
        #expect(disconnected.toolDescriptors == connected.toolDescriptors)
        #expect(try await runtime.unifiedToolRegistry(base: .empty).descriptors.isEmpty)
    }

    @Test("changing a server endpoint clears its previous capability catalog")
    func endpointChangeClearsCatalog() async throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let serverRegistry = MCPServerRegistry(store: store)
        let server = try serverRegistry.create(displayName: "Local tools", endpoint: "https://mcp.example.test/mcp")
        _ = try serverRegistry.setEnabled(id: server.id, enabled: true)
        let runtime = MCPServerRuntime(
            registry: serverRegistry,
            store: store,
            credentials: CredentialStore(secrets: InMemorySecretBackend(),
                                          metadataRepository: InMemoryCredentialMetadataRepository()),
            transport: MCPFixtureTransport()
        )

        let connected = try await runtime.connect(serverID: server.id)
        #expect(!connected.tools.isEmpty)
        _ = await runtime.disconnect(serverID: server.id)
        _ = try serverRegistry.update(id: server.id, displayName: "Moved tools",
                                      endpoint: "https://other.example.test/mcp")

        let snapshot = try #require(try await runtime.snapshots().first)
        #expect(snapshot.state == .disconnected)
        #expect(snapshot.tools.isEmpty)
        #expect(snapshot.toolDescriptors.isEmpty)
    }

    @Test("enabling a configured server derives its disconnected state")
    func enabledStateIsDerivedFromConfiguration() async throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let serverRegistry = MCPServerRegistry(store: store)
        let server = try serverRegistry.create(displayName: "Local tools", endpoint: "https://mcp.example.test/mcp")
        let runtime = MCPServerRuntime(
            registry: serverRegistry,
            store: store,
            credentials: CredentialStore(secrets: InMemorySecretBackend(),
                                          metadataRepository: InMemoryCredentialMetadataRepository()),
            transport: MCPFixtureTransport()
        )

        #expect(try await runtime.snapshots().first?.state == .disabled)
        _ = try serverRegistry.setEnabled(id: server.id, enabled: true)
        #expect(try await runtime.snapshots().first?.state == .disconnected)
    }

    @Test("Bearer credential references resolve again at each MCP request")
    func credentialReferenceIsResolvedAtRequestBoundary() async throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let serverRegistry = MCPServerRegistry(store: store)
        let credentials = CredentialStore(secrets: InMemorySecretBackend(), metadataRepository: store)
        let credential = CredentialReference(id: "mcp-provider-credential")
        try credentials.provision(SecretValue("fixture-mcp-bearer-one"), as: credential)

        let server = try serverRegistry.create(displayName: "Provider-auth MCP", endpoint: "https://mcp.example.test/mcp")
        _ = try serverRegistry.setEnabled(id: server.id, enabled: true)
        _ = try serverRegistry.setAuthenticationReference(id: server.id, reference: .credential(credential))
        let transport = MCPFixtureTransport()
        let runtime = MCPServerRuntime(registry: serverRegistry, store: store,
                                       credentials: credentials, transport: transport)

        let snapshot = try await runtime.connect(serverID: server.id)
        try credentials.refresh(SecretValue("fixture-mcp-bearer-two"), for: credential)
        let unified = try await runtime.unifiedToolRegistry(base: .empty)
        let executable = try #require(unified.executor(id: snapshot.toolDescriptors[0].id))
        let intent = try executable.prepare(callID: "call-2", argumentsJSON: #"{"query":"hello"}"#)
        _ = try await executable.execute(intent, idempotencyKey: "call-2")

        #expect(transport.authorizationHeaders == [
            "Bearer fixture-mcp-bearer-one",
            "Bearer fixture-mcp-bearer-one",
            "Bearer fixture-mcp-bearer-two"
        ])

        try credentials.rebind(
            SecretValue("fixture-mcp-bearer-three"),
            as: credential,
            principalFingerprint: "fixture-account-two"
        )
        let afterCredentialRebind = try await runtime.unifiedToolRegistry(base: .empty)
        #expect(afterCredentialRebind.descriptors.isEmpty)
        #expect(try await runtime.connectionSnapshot(serverID: server.id)?.state == .authenticationRequired)

        let environmentRuntime = EnvironmentRuntime(store: store, credentials: credentials)
        let environmentSecret = try await environmentRuntime.saveSecret(
            key: "MCP_BEARER",
            value: SecretValue("fixture-mcp-environment-bearer")
        )
        let environmentServer = try serverRegistry.create(
            displayName: "Environment-auth MCP",
            endpoint: "https://mcp-env.example.test/mcp"
        )
        _ = try serverRegistry.setEnabled(id: environmentServer.id, enabled: true)
        _ = try serverRegistry.setAuthenticationReference(
            id: environmentServer.id,
            reference: .globalEnvironment(environmentSecret.reference)
        )
        let environmentRuntimeClient = MCPServerRuntime(
            registry: serverRegistry,
            store: store,
            credentials: credentials,
            transport: transport
        )
        let environmentSnapshot = try await environmentRuntimeClient.connect(serverID: environmentServer.id)
        let environmentTools = try await environmentRuntimeClient.unifiedToolRegistry(base: .empty)
        let environmentExecutable = try #require(
            environmentTools.executor(id: environmentSnapshot.toolDescriptors[0].id)
        )
        let environmentIntent = try environmentExecutable.prepare(
            callID: "call-3",
            argumentsJSON: #"{"query":"hello"}"#
        )
        _ = try await environmentExecutable.execute(environmentIntent, idempotencyKey: "call-3")
        #expect(transport.authorizationHeaders.suffix(2) == [
            "Bearer fixture-mcp-environment-bearer",
            "Bearer fixture-mcp-environment-bearer"
        ])

        try await environmentRuntime.delete(id: environmentSecret.id)
        let afterEnvironmentDeletion = try await environmentRuntimeClient.unifiedToolRegistry(base: .empty)
        #expect(afterEnvironmentDeletion.descriptors.isEmpty)
        #expect(try await environmentRuntimeClient.connectionSnapshot(serverID: environmentServer.id)?.state
            == .authenticationRequired)
    }
}

private final class MCPFixtureTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [HTTPRequest] = []

    var authorizationHeaders: [String] {
        lock.withLock {
            recorded.compactMap { request in
                request.headers.first { $0.key.caseInsensitiveCompare("Authorization") == .orderedSame }?.value
            }
        }
    }

    var methods: [String] {
        lock.withLock {
            recorded.compactMap { request in
                guard let body = request.body,
                      let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
                else { return nil }
                return object["method"] as? String
            }
        }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        throw HTTPTransportError.networkFailure("MCP fixture expects Streamable HTTP requests")
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        guard let body = request.body,
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let method = object["method"] as? String,
              let id = object["id"] as? String else {
            throw MCPClientError.invalidResponse
        }
        lock.withLock { recorded.append(request) }

        let result: [String: Any]
        switch method {
        case "server/discover":
            result = [
                "resultType": "complete",
                "supportedVersions": [MCPProtocolVersion.modern],
                "capabilities": ["tools": [String: Any]()],
                "_meta": ["io.modelcontextprotocol/serverInfo": ["name": "Fixture MCP", "version": "1"]]
            ]
        case "tools/list":
            result = [
                "resultType": "complete",
                "tools": [[
                    "name": "lookup",
                    "description": "Look up a fixture value.",
                    "inputSchema": [
                        "type": "object",
                        "properties": ["query": ["type": "string"]],
                        "required": ["query"]
                    ]
                ]]
            ]
        case "tools/call":
            result = ["resultType": "complete", "content": [["type": "text", "text": "fixture result"]]]
        default:
            throw MCPClientError.rpcError(code: -32601, message: "Unknown fixture method")
        }

        let response: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        let responseData = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
        return HTTPStream(
            body: AsyncThrowingStream { continuation in
                continuation.yield(responseData)
                continuation.finish()
            },
            cancel: {}
        )
    }
}

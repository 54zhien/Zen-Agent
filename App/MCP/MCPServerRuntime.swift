import Foundation

actor MCPServerRuntime {
    private struct ConfigurationIdentity: Equatable, Sendable {
        let serverID: String
        let endpoint: String
        let authenticationReference: MCPAuthenticationReference?
    }

    private let registry: MCPServerRegistry
    private let store: PersistenceStore
    private let credentials: any CredentialStoring
    private let transport: any HTTPTransport

    private var connections: [String: MCPConnection] = [:]
    private var connectionTasks: [String: Task<MCPServerConnectionSnapshot, Error>] = [:]
    private var identities: [String: ConfigurationIdentity] = [:]
    private var snapshotsByID: [String: MCPServerConnectionSnapshot] = [:]
    private var generations: [String: UInt64] = [:]

    init(
        registry: MCPServerRegistry,
        store: PersistenceStore,
        credentials: any CredentialStoring,
        transport: any HTTPTransport
    ) {
        self.registry = registry
        self.store = store
        self.credentials = credentials
        self.transport = transport
    }

    func snapshots() async throws -> [MCPServerConnectionSnapshot] {
        let configured = try registry.list()
        let currentIDs = Set(configured.map(\.id))
        for serverID in Set(identities.keys).subtracting(currentIDs) {
            await discard(serverID: serverID)
        }

        var result: [MCPServerConnectionSnapshot] = []
        result.reserveCapacity(configured.count)
        for server in configured {
            let identity = Self.identity(for: server)
            if let existing = identities[server.id], existing != identity {
                await discard(serverID: server.id)
            }
            identities[server.id] = identity

            if !server.enabled, connections[server.id] != nil {
                _ = await disconnect(serverID: server.id)
            }

            if let connection = connections[server.id], server.enabled, connection.isAvailable() {
                if let snapshot = snapshotsByID[server.id] {
                    result.append(snapshot)
                } else {
                    result.append(.configuration(server: server))
                }
            } else if let connection = connections[server.id], server.enabled {
                _ = connection
                let previous = snapshotsByID[server.id] ?? .configuration(server: server)
                let snapshot = Self.replacingState(
                    previous,
                    with: .disconnected,
                    lastError: Self.safeSummary(for: MCPClientError.connectionUnavailable)
                )
                snapshotsByID[server.id] = snapshot
                result.append(snapshot)
            } else if let cached = snapshotsByID[server.id] {
                let state = server.enabled
                    ? (cached.state == .disabled ? .disconnected : cached.state)
                    : .disabled
                result.append(Self.replacingState(cached, with: state))
            } else {
                result.append(.configuration(server: server))
            }
        }
        return result
    }

    func connectionSnapshot(serverID: String) -> MCPServerConnectionSnapshot? {
        snapshotsByID[serverID]
    }

    func connect(serverID: String) async throws -> MCPServerConnectionSnapshot {
        guard let server = try registry.server(id: serverID) else {
            throw MCPServerRegistryError.notFound
        }
        let identity = Self.identity(for: server)
        if let existing = identities[serverID], existing != identity {
            await discard(serverID: serverID)
        }
        identities[serverID] = identity

        guard server.enabled else {
            return await disconnect(serverID: serverID)
        }
        if connections[serverID]?.isAvailable() == true,
           let current = snapshotsByID[serverID], current.state == .connected {
            return current
        }
        if let task = connectionTasks[serverID] {
            return try await task.value
        }

        if let previousConnection = connections.removeValue(forKey: serverID) {
            await previousConnection.disconnect()
        }

        let generation = generations[serverID, default: 0]
        let previous = snapshotsByID[serverID] ?? .configuration(server: server)
        snapshotsByID[serverID] = Self.replacingState(previous, with: .connecting, lastError: nil)
        let task = Task { try await self.establish(server: server, identity: identity, generation: generation) }
        connectionTasks[serverID] = task
        do {
            let snapshot = try await task.value
            if generations[serverID, default: 0] == generation { connectionTasks.removeValue(forKey: serverID) }
            return snapshot
        } catch {
            if generations[serverID, default: 0] == generation { connectionTasks.removeValue(forKey: serverID) }
            throw error
        }
    }

    func disconnect(serverID: String) async -> MCPServerConnectionSnapshot {
        generations[serverID, default: 0] &+= 1
        connectionTasks.removeValue(forKey: serverID)?.cancel()
        let connection = connections.removeValue(forKey: serverID)
        if let connection { await connection.disconnect() }

        let server = try? registry.server(id: serverID)
        let previous = snapshotsByID[serverID]
        guard let server else {
            snapshotsByID.removeValue(forKey: serverID)
            identities.removeValue(forKey: serverID)
            return previous ?? MCPServerConnectionSnapshot(
                serverID: serverID,
                state: .disconnected,
                lastError: nil,
                serverInfo: nil,
                tools: [],
                resources: [],
                prompts: [],
                toolDescriptors: []
            )
        }
        identities[serverID] = Self.identity(for: server)
        let state: MCPServerConnectionState = server.enabled ? .disconnected : .disabled
        let snapshot = previous.map { Self.replacingState($0, with: state) }
            ?? MCPServerConnectionSnapshot.configuration(server: server)
        snapshotsByID[serverID] = snapshot
        return snapshot
    }

    func reconnectEnabledServers() async {
        guard let configured = try? registry.list() else { return }
        for server in configured {
            if server.enabled {
                _ = try? await connect(serverID: server.id)
            } else {
                _ = await disconnect(serverID: server.id)
            }
        }
    }

    func unifiedToolRegistry(base: ToolRegistry) throws -> ToolRegistry {
        try unifiedToolContext(base: base).registry
    }

    func unifiedToolContext(
        base: ToolRegistry
    ) throws -> (
        registry: ToolRegistry,
        availableServerIDs: Set<String>,
        availableServerIdentities: [String: MCPServerDependencyIdentity]
    ) {
        let configured = try registry.list()
        var executables: [any ToolExecutable] = []
        var availableServerIDs = Set<String>()
        var availableServerIdentities: [String: MCPServerDependencyIdentity] = [:]
        for server in configured where server.enabled {
            guard identities[server.id] == Self.identity(for: server),
                  let connection = connections[server.id],
                  snapshotsByID[server.id]?.state == .connected else { continue }
            guard connection.isAvailable() else {
                if let snapshot = snapshotsByID[server.id] {
                    snapshotsByID[server.id] = Self.replacingState(
                        snapshot,
                        with: .disconnected,
                        lastError: Self.safeSummary(for: MCPClientError.connectionUnavailable)
                    )
                }
                continue
            }
            do {
                try connection.authentication?.validate()
            } catch let error as MCPClientError where error == .authenticationRequired {
                if let snapshot = snapshotsByID[server.id] {
                    snapshotsByID[server.id] = Self.replacingState(
                        snapshot,
                        with: .authenticationRequired,
                        lastError: Self.safeSummary(for: error)
                    )
                }
                continue
            }
            availableServerIDs.insert(server.id)
            availableServerIdentities[server.id] = MCPServerDependencyIdentity(
                serverID: server.id,
                endpointIdentity: connection.endpointIdentity,
                authenticationIdentity: connection.authenticationIdentity
            )
            for definition in connection.tools where MCPRequestBuilder.hasValidHeaderParameters(in: definition.inputSchema) {
                executables.append(MCPToolExecutable(server: server, connection: connection, definition: definition))
            }
        }
        return (try base.merging(executables), availableServerIDs, availableServerIdentities)
    }

    private func establish(
        server: MCPServer,
        identity: ConfigurationIdentity,
        generation: UInt64
    ) async throws -> MCPServerConnectionSnapshot {
        do {
            let authentication = MCPAuthenticationResolver(
                reference: server.authenticationReference,
                store: store,
                credentials: credentials
            )
            let connection = try await MCPClient(transport: transport, authentication: authentication)
                .connect(server: server)
            guard generations[server.id, default: 0] == generation,
                  let current = try registry.server(id: server.id),
                  current.enabled,
                  Self.identity(for: current) == identity else {
                await connection.disconnect()
                if generations[server.id, default: 0] == generation {
                    _ = await disconnect(serverID: server.id)
                }
                throw MCPClientError.serverConfigurationChanged
            }

            let descriptors = connection.tools
                .filter { MCPRequestBuilder.hasValidHeaderParameters(in: $0.inputSchema) }
                .map { MCPToolExecutable(server: current, connection: connection, definition: $0).descriptor }
            connections[server.id] = connection
            identities[server.id] = identity
            let snapshot = MCPServerConnectionSnapshot(
                serverID: server.id,
                state: .connected,
                lastError: nil,
                serverInfo: connection.serverInfo,
                tools: connection.tools,
                resources: connection.resources,
                prompts: connection.prompts,
                toolDescriptors: descriptors
            )
            snapshotsByID[server.id] = snapshot
            return snapshot
        } catch {
            if generations[server.id, default: 0] == generation {
                let previous = snapshotsByID[server.id] ?? .configuration(server: server)
                let state: MCPServerConnectionState = error as? MCPClientError == .authenticationRequired
                    ? .authenticationRequired : .failed
                snapshotsByID[server.id] = Self.replacingState(
                    previous,
                    with: state,
                    lastError: Self.safeSummary(for: error)
                )
            }
            throw error
        }
    }

    private func discard(serverID: String) async {
        generations[serverID, default: 0] &+= 1
        connectionTasks.removeValue(forKey: serverID)?.cancel()
        let connection = connections.removeValue(forKey: serverID)
        snapshotsByID.removeValue(forKey: serverID)
        identities.removeValue(forKey: serverID)
        if let connection { await connection.disconnect() }
    }

    private static func identity(for server: MCPServer) -> ConfigurationIdentity {
        ConfigurationIdentity(
            serverID: server.id,
            endpoint: server.endpoint,
            authenticationReference: server.authenticationReference
        )
    }

    private static func replacingState(
        _ snapshot: MCPServerConnectionSnapshot,
        with state: MCPServerConnectionState,
        lastError: String? = nil
    ) -> MCPServerConnectionSnapshot {
        MCPServerConnectionSnapshot(
            serverID: snapshot.serverID,
            state: state,
            lastError: lastError ?? snapshot.lastError,
            serverInfo: snapshot.serverInfo,
            tools: snapshot.tools,
            resources: snapshot.resources,
            prompts: snapshot.prompts,
            toolDescriptors: snapshot.toolDescriptors
        )
    }

    private static func safeSummary(for error: Error) -> String {
        guard let error = error as? MCPClientError else { return "MCP 服务连接失败。" }
        switch error {
        case .invalidEndpoint:
            "服务地址无效。"
        case .unsupportedProtocol:
            "服务使用了不受支持的 MCP 协议版本。"
        case .httpStatus(let status):
            "MCP 服务返回 HTTP \(status)。"
        case .rpcError(let code, _):
            "MCP 服务拒绝了请求（\(code)）。"
        case .invalidResponse:
            "MCP 服务返回了无法读取的响应。"
        case .connectionUnavailable:
            "MCP 连接已断开。"
        case .serverConfigurationChanged:
            "连接期间服务配置已变化。"
        case .authenticationRequired:
            "所选凭据不可用或已失效。"
        }
    }
}

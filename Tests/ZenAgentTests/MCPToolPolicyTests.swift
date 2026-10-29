import CryptoKit
import Foundation
import Testing

@testable import ZenAgent

@Suite("MCP Tool policy")
struct MCPToolPolicyTests {
    @Test("MCP calls use the shared approval path and freeze their server destination")
    func mcpCallUsesSharedPolicy() async throws {
        let fixture = try await MCPToolPolicyFixture.make()
        let descriptor = try #require(fixture.registry.descriptors.first)
        let runID = "mcp-policy-run"
        try MCPToolPolicyFixture.prepareRun(
            store: fixture.store,
            runID: runID,
            conversationID: "mcp-policy-conversation",
            messageID: "mcp-policy-message",
            descriptor: descriptor
        )
        try fixture.store.setToolPolicy(
            toolID: descriptor.id,
            actionID: try #require(descriptor.actions.first?.actionID),
            descriptorRevision: descriptor.revision,
            mode: .alwaysAllow
        )

        let runtime = ToolRuntime(store: fixture.store, registry: .empty, credentials: fixture.credentials)
        runtime.bind(registry: fixture.registry, forRunID: runID)

        #expect(try await runtime.complete(
            agentRunID: runID,
            providerCallID: "provider-call",
            toolID: descriptor.id,
            argumentsJSON: #"{"query":"hello"}"#,
            batchID: "mcp-policy-batch",
            batchSequence: 0
        ) == nil)
        let call = try #require(try fixture.store.toolCalls(inRun: runID).first)
        #expect(call.state == .waitingForApproval)
        #expect(fixture.transport.methods == ["server/discover", "tools/list"])

        let intent = try #require(try call.executionIntent.map(ToolIntentCodec.decodeForDisplay))
        let expectedEndpoint = SHA256.hash(data: Data("https://mcp.example.test/mcp".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let destination = ToolDestinationScope.mcpServer(
            serverID: fixture.server.id,
            endpointIdentity: expectedEndpoint
        )
        #expect(intent.destinationScope == destination)

        try runtime.approve(toolCallID: call.id)
        let grants = try fixture.store.toolGrants(subject: .parentConversation("mcp-policy-conversation"))
        #expect(grants.count == 1)
        #expect(grants.first?.grant.destination == destination)
        #expect(try await runtime.executeApproved(toolCallID: call.id).content == "fixture result")
        #expect(fixture.transport.methods == ["server/discover", "tools/list", "tools/call"])
        #expect(try fixture.store.toolCall(id: call.id)?.state == .succeeded)
    }

    @Test("reconnecting cannot redirect an approved Run to the replacement MCP connection")
    func reconnectKeepsTheRunBoundToItsOriginalConnection() async throws {
        let first = try await MCPToolPolicyFixture.make()
        let descriptor = try #require(first.registry.descriptors.first)
        let runID = "mcp-reconnect-run"
        try MCPToolPolicyFixture.prepareRun(
            store: first.store,
            runID: runID,
            conversationID: "mcp-reconnect-conversation",
            messageID: "mcp-reconnect-message",
            descriptor: descriptor
        )

        let runtime = ToolRuntime(store: first.store, registry: .empty, credentials: first.credentials)
        runtime.bind(registry: first.registry, forRunID: runID)
        #expect(try await runtime.complete(
            agentRunID: runID,
            providerCallID: "provider-call",
            toolID: descriptor.id,
            argumentsJSON: #"{"query":"hello"}"#,
            batchID: "mcp-reconnect-batch",
            batchSequence: 0
        ) == nil)
        let call = try #require(try first.store.toolCalls(inRun: runID).first)
        try runtime.approve(toolCallID: call.id)

        _ = await first.serverRuntime.disconnect(serverID: first.server.id)
        _ = try first.serverRegistry.update(
            id: first.server.id,
            displayName: "Moved MCP",
            endpoint: "https://other.example.test/mcp"
        )
        let replacementTransport = MCPToolPolicyFixtureTransport()
        let replacementRuntime = MCPServerRuntime(
            registry: first.serverRegistry,
            store: first.store,
            credentials: first.credentials,
            transport: replacementTransport
        )
        _ = try await replacementRuntime.connect(serverID: first.server.id)
        let replacementRegistry = try await replacementRuntime.unifiedToolRegistry(base: .empty)
        let replacementDescriptor = try #require(replacementRegistry.descriptors.first)
        #expect(replacementDescriptor.id == descriptor.id)
        #expect(replacementDescriptor.revision != descriptor.revision)

        runtime.rebindRecoveredRun(registry: replacementRegistry, forRunID: runID)
        let result = try await runtime.executeApproved(toolCallID: call.id)
        #expect(result.failure == .dependencyChanged)
        #expect(try first.store.toolCall(id: call.id)?.state == .rejected)
        #expect(first.transport.methods == ["server/discover", "tools/list"])
        #expect(replacementTransport.methods == ["server/discover", "tools/list"])
    }

    @Test("replacing an MCP Environment credential fails before dispatch and hides the stale server")
    func replacedEnvironmentCredentialCannotDispatch() async throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let credentials = CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: store
        )
        let environment = EnvironmentRuntime(store: store, credentials: credentials)
        let original = try await environment.saveSecret(
            key: "MCP_AUTH",
            value: SecretValue("fixture-mcp-auth-old")
        )
        let serverRegistry = MCPServerRegistry(store: store)
        let server = try serverRegistry.create(
            displayName: "Authenticated fixture",
            endpoint: "https://mcp.example.test/mcp"
        )
        _ = try serverRegistry.setEnabled(id: server.id, enabled: true)
        _ = try serverRegistry.setAuthenticationReference(
            id: server.id,
            reference: .globalEnvironment(original.reference)
        )
        let transport = MCPToolPolicyFixtureTransport()
        let serverRuntime = MCPServerRuntime(
            registry: serverRegistry,
            store: store,
            credentials: credentials,
            transport: transport
        )
        _ = try await serverRuntime.connect(serverID: server.id)
        let context = try await serverRuntime.unifiedToolContext(base: .empty)
        let descriptor = try #require(context.registry.descriptors.first)
        let runID = "mcp-environment-auth-run"
        try MCPToolPolicyFixture.prepareRun(
            store: store,
            runID: runID,
            conversationID: "mcp-environment-auth-conversation",
            messageID: "mcp-environment-auth-message",
            descriptor: descriptor
        )

        let runtime = ToolRuntime(store: store, registry: .empty, credentials: credentials)
        runtime.bind(
            registry: context.registry,
            availableMCPServerIDs: context.availableServerIDs,
            availableMCPServerIdentities: context.availableServerIdentities,
            forRunID: runID
        )
        #expect(try await runtime.complete(
            agentRunID: runID,
            providerCallID: "provider-call",
            toolID: descriptor.id,
            argumentsJSON: #"{"query":"hello"}"#,
            batchID: "mcp-environment-auth-batch",
            batchSequence: 0
        ) == nil)
        let call = try #require(try store.toolCalls(inRun: runID).first)
        try runtime.approve(toolCallID: call.id)

        _ = try await environment.saveSecret(
            id: original.id,
            expectedRevisionID: original.revisionID,
            key: original.key,
            value: SecretValue("fixture-mcp-auth-new")
        )
        let result = try await runtime.executeApproved(toolCallID: call.id)
        #expect(result.failure == .dependencyChanged)
        #expect(try store.toolCall(id: call.id)?.state == .rejected)
        #expect(transport.methods == ["server/discover", "tools/list"])

        let refreshedContext = try await serverRuntime.unifiedToolContext(base: .empty)
        #expect(!refreshedContext.availableServerIDs.contains(server.id))
        #expect(refreshedContext.registry.descriptors.isEmpty)
    }

    @Test("MCP-backed Skill dependencies survive frozen Run recovery when the same server is available")
    func mcpSkillDependenciesResolveThroughRecoveredRunRegistry() async throws {
        let fixture = try await MCPToolPolicyFixture.make()
        let descriptor = try #require(fixture.registry.descriptors.first)
        let serverDependency = try #require(
            fixture.registry.mcpServerDependencyIdentities[fixture.server.id]
        )
        let skills = SkillRuntime(
            store: fixture.store,
            credentials: fixture.credentials,
            registry: fixture.registry,
            availableMCPServerIDs: [fixture.server.id],
            availableMCPServerIdentities: [fixture.server.id: serverDependency]
        )
        let skill = try skills.saveUser(definition: SkillDefinition(
            name: "Fixture MCP workflow",
            summary: "Requires this MCP server and tool.",
            instructions: "Use the approved MCP tool when the workflow needs it.",
            requiredTools: [descriptor.id],
            requiredMCPServers: [fixture.server.id]
        ))
        try await skills.setEnabled(id: skill.id, enabled: true)
        let activation = try skills.prepare(query: "hello", selectedSkillIDs: [skill.id])
        #expect(activation.count == 1)

        let runID = "mcp-skill-recovery-run"
        var commit = Fixtures.send(
            conversationID: "mcp-skill-recovery-conversation",
            messageID: "mcp-skill-recovery-message",
            runID: runID
        )
        commit.skillReferences = activation.map(\.reference)
        try fixture.store.commitUserTurnAndCreateParentRun(commit)
        let snapshot = RunExecutionSnapshot(
            providerID: .deepSeek,
            providerAdapterRevision: "mcp-skill-recovery-test",
            prompt: PromptExecutionSnapshot(
                runtimeSafetyBaseline: PromptTemplateCatalog.currentRuntimeSafetyRevision,
                zenCore: PromptTemplateCatalog.currentZenCoreRevision,
                providerAdapterInstructions: "",
                skillReferences: activation.map(\.reference)
            ),
            modelCapabilities: [.text, .streaming, .tools],
            exposedTools: [ToolExposureSnapshot(
                toolID: descriptor.id,
                descriptorRevision: descriptor.revision,
                displayName: descriptor.displayName,
                description: descriptor.description,
                inputSchema: descriptor.inputSchema
            )],
            mcpServerDependencies: [serverDependency],
            maxProviderSteps: 4
        )
        try fixture.store.completeExecutionSnapshot(
            runID: runID,
            encodedSnapshot: try ExecutionSnapshotCodec.encode(snapshot)
        )
        try fixture.store.transitionRun(id: runID, expectedState: .preparing, to: .requestingModel)

        let toolRuntime = ToolRuntime(store: fixture.store, registry: .empty, credentials: fixture.credentials)
        toolRuntime.bind(
            registry: fixture.registry,
            availableMCPServerIDs: [fixture.server.id],
            availableMCPServerIdentities: [fixture.server.id: serverDependency],
            forRunID: runID
        )
        try await RunRecovery(store: fixture.store, toolRuntime: toolRuntime).recover(runID: runID)
        #expect(try fixture.store.run(id: runID)?.endReason == .streamInterrupted)
    }

    @Test("ConversationRuntime exposes the connected MCP catalog in the frozen Run and provider request")
    func newRunFreezesAndExposesConnectedMCPTools() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let serverRegistry = MCPServerRegistry(store: fixture.store)
        let server = try serverRegistry.create(
            displayName: "Conversation fixture",
            endpoint: "https://mcp.example.test/mcp"
        )
        _ = try serverRegistry.setEnabled(id: server.id, enabled: true)
        let transport = MCPToolPolicyFixtureTransport()
        let serverRuntime = MCPServerRuntime(
            registry: serverRegistry,
            store: fixture.store,
            credentials: fixture.credentials,
            transport: transport
        )
        _ = try await serverRuntime.connect(serverID: server.id)

        let ledger = MCPProviderRequestLedger()
        let provider = MCPRequestRecordingProvider(base: FakeProvider(
            id: .deepSeek,
            instanceID: fixture.instance.id,
            modelNames: [I05RuntimeTestFixtures.modelID.rawValue],
            capabilities: [.text, .streaming, .tools],
            scriptedEvents: [.textDelta("fixture response"), .finish(.stop)]
        ), ledger: ledger)
        let runtime = ConversationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials,
            toolRegistry: .empty,
            toolRuntime: ToolRuntime(store: fixture.store, registry: .empty, credentials: fixture.credentials),
            mcpRuntime: serverRuntime
        )

        let runID = try await runtime.send(I05RuntimeTestFixtures.command())
        let persistedRun = try fixture.store.run(id: runID)
        let run = try #require(persistedRun)
        #expect(run.state == .completed)
        let snapshot = try ExecutionSnapshotCodec.decode(try #require(run.executionSnapshot))
        let discoveredRegistry = try await serverRuntime.unifiedToolRegistry(base: .empty)
        let descriptor = try #require(discoveredRegistry.descriptors.first)
        #expect(snapshot.exposedTools.map(\.toolID) == [descriptor.id])
        let requests = await ledger.snapshot()
        #expect(requests.count == 1)
        #expect(requests.first?.tools.map(\.name) == [descriptor.id])
        #expect(transport.methods == ["server/discover", "tools/list"])
    }

    @Test("an MCP server with no tools can satisfy a frozen Skill server dependency")
    func skillCanFreezeServerWithoutTools() async throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let credentials = CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: store
        )
        let serverRegistry = MCPServerRegistry(store: store)
        let server = try serverRegistry.create(
            displayName: "Resources only",
            endpoint: "https://mcp.example.test/resources"
        )
        _ = try serverRegistry.setEnabled(id: server.id, enabled: true)
        let firstRuntime = MCPServerRuntime(
            registry: serverRegistry,
            store: store,
            credentials: credentials,
            transport: MCPToolPolicyFixtureTransport(includesTool: false)
        )
        _ = try await firstRuntime.connect(serverID: server.id)
        let firstContext = try await firstRuntime.unifiedToolContext(base: .empty)
        #expect(firstContext.registry.descriptors.isEmpty)
        #expect(firstContext.availableServerIDs.contains(server.id))

        let skills = SkillRuntime(
            store: store,
            credentials: credentials,
            registry: firstContext.registry,
            availableMCPServerIDs: firstContext.availableServerIDs,
            availableMCPServerIdentities: firstContext.availableServerIdentities
        )
        let skill = try skills.saveUser(definition: SkillDefinition(
            name: "Server-dependent workflow",
            summary: "Requires the configured server.",
            instructions: "Use the workflow instructions.",
            requiredMCPServers: [server.id]
        ))
        try await skills.setEnabled(id: skill.id, enabled: true)
        let activation = try skills.prepare(query: "workflow", selectedSkillIDs: [skill.id])
        let frozenDependencies = try skills.requiredMCPServerDependencies(
            for: activation.map(\.reference)
        )
        #expect(frozenDependencies == [try #require(firstContext.availableServerIdentities[server.id])])

        _ = try serverRegistry.update(
            id: server.id,
            displayName: "Moved resources",
            endpoint: "https://other.example.test/resources"
        )
        let movedRuntime = MCPServerRuntime(
            registry: serverRegistry,
            store: store,
            credentials: credentials,
            transport: MCPToolPolicyFixtureTransport(includesTool: false)
        )
        _ = try await movedRuntime.connect(serverID: server.id)
        let movedContext = try await movedRuntime.unifiedToolContext(base: .empty)
        let recoveredSkills = SkillRuntime(
            store: store,
            credentials: credentials,
            registry: movedContext.registry,
            availableMCPServerIDs: movedContext.availableServerIDs,
            availableMCPServerIdentities: movedContext.availableServerIdentities,
            frozenMCPServerDependencies: frozenDependencies
        )
        #expect(throws: SkillError.erasedDependency) {
            try recoveredSkills.resolveFrozen(activation.map(\.reference))
        }
    }
}

private struct MCPToolPolicyFixture {
    let store: PersistenceStore
    let credentials: CredentialStore
    let serverRegistry: MCPServerRegistry
    let serverRuntime: MCPServerRuntime
    let transport: MCPToolPolicyFixtureTransport
    let server: MCPServer
    let registry: ToolRegistry

    static func make() async throws -> Self {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let serverRegistry = MCPServerRegistry(store: store)
        let server = try serverRegistry.create(
            displayName: "Fixture MCP",
            endpoint: "https://mcp.example.test/mcp"
        )
        _ = try serverRegistry.setEnabled(id: server.id, enabled: true)
        let credentials = CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: InMemoryCredentialMetadataRepository()
        )
        let transport = MCPToolPolicyFixtureTransport()
        let serverRuntime = MCPServerRuntime(
            registry: serverRegistry,
            store: store,
            credentials: credentials,
            transport: transport
        )
        _ = try await serverRuntime.connect(serverID: server.id)
        let registry = try await serverRuntime.unifiedToolRegistry(base: .empty)
        return Self(store: store, credentials: credentials, serverRegistry: serverRegistry,
                    serverRuntime: serverRuntime, transport: transport, server: server, registry: registry)
    }

    static func prepareRun(store: PersistenceStore, runID: String, conversationID: String,
                           messageID: String, descriptor: ToolDescriptor) throws {
        try store.commitUserTurnAndCreateParentRun(Fixtures.send(
            conversationID: conversationID,
            messageID: messageID,
            runID: runID
        ))
        let snapshot = RunExecutionSnapshot(
            providerID: .deepSeek,
            providerAdapterRevision: "mcp-policy-test",
            prompt: PromptExecutionSnapshot(
                runtimeSafetyBaseline: PromptTemplateCatalog.currentRuntimeSafetyRevision,
                zenCore: PromptTemplateCatalog.currentZenCoreRevision,
                providerAdapterInstructions: ""
            ),
            modelCapabilities: [.text, .streaming, .tools],
            exposedTools: [ToolExposureSnapshot(
                toolID: descriptor.id,
                descriptorRevision: descriptor.revision,
                displayName: descriptor.displayName,
                description: descriptor.description,
                inputSchema: descriptor.inputSchema
            )],
            maxProviderSteps: 4
        )
        try store.completeExecutionSnapshot(
            runID: runID,
            encodedSnapshot: try ExecutionSnapshotCodec.encode(snapshot)
        )
        try store.transitionRun(id: runID, expectedState: .preparing, to: .requestingModel)
        try store.transitionRun(id: runID, expectedState: .requestingModel, to: .toolRequested)
        try store.transitionRun(id: runID, expectedState: .toolRequested, to: .executingTools)
    }
}

private final class MCPToolPolicyFixtureTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [HTTPRequest] = []
    private let includesTool: Bool

    init(includesTool: Bool = true) {
        self.includesTool = includesTool
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
        throw HTTPTransportError.networkFailure("MCP policy fixture expects Streamable HTTP requests")
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
                "tools": includesTool ? [[
                    "name": "lookup",
                    "description": "Look up a fixture value.",
                    "inputSchema": [
                        "type": "object",
                        "properties": ["query": ["type": "string"]],
                        "required": ["query"]
                    ]
                ]] : []
            ]
        case "tools/call":
            result = ["resultType": "complete", "content": [["type": "text", "text": "fixture result"]]]
        default:
            throw MCPClientError.rpcError(code: -32601, message: "Unknown fixture method")
        }

        let response: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
        return HTTPStream(
            body: AsyncThrowingStream { continuation in
                continuation.yield(data)
                continuation.finish()
            },
            cancel: {}
        )
    }
}

private actor MCPProviderRequestLedger {
    private var requests: [ProviderChatRequest] = []

    func record(_ request: ProviderChatRequest) { requests.append(request) }
    func snapshot() -> [ProviderChatRequest] { requests }
}

private struct MCPRequestRecordingProvider: ModelProvider {
    let base: FakeProvider
    let ledger: MCPProviderRequestLedger

    var id: ProviderID { base.id }
    var adapterRevision: String { base.adapterRevision }
    var adapterPromptInstructions: String { base.adapterPromptInstructions }

    func knownModels(for instance: ProviderInstance) -> [ModelDescriptor] {
        base.knownModels(for: instance)
    }

    func descriptor(for modelID: ModelID, in instance: ProviderInstance) -> ModelDescriptor? {
        base.descriptor(for: modelID, in: instance)
    }

    func makeRequestConfigSeed(
        instance: ProviderInstance,
        modelID: ModelID,
        credentialBinding: CredentialBindingSnapshot
    ) throws -> RequestConfigSeed {
        try base.makeRequestConfigSeed(
            instance: instance,
            modelID: modelID,
            credentialBinding: credentialBinding
        )
    }

    func stream(
        _ request: ProviderChatRequest,
        seed: RequestConfigSeed,
        credentials: any CredentialStoring
    ) async throws -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        await ledger.record(request)
        return try await base.stream(request, seed: seed, credentials: credentials)
    }
}

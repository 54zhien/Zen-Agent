import CryptoKit
import Foundation

struct MCPToolExecutable: ToolExecutable {
    static let actionID = "call"

    let server: MCPServer
    let connection: MCPConnection
    let definition: MCPToolDefinition
    let descriptor: ToolDescriptor
    let endpointIdentity: String

    init(server: MCPServer, connection: MCPConnection, definition: MCPToolDefinition) {
        self.server = server
        self.connection = connection
        self.definition = definition
        endpointIdentity = connection.endpointIdentity
        descriptor = Self.makeDescriptor(
            server: server,
            connection: connection,
            definition: definition,
            endpointIdentity: endpointIdentity
        )
    }

    static func toolID(serverID: String, toolName: String) -> String {
        let encodedName = Data(toolName.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "mcp:\(serverID):\(encodedName)"
    }

    static func serverID(forToolID toolID: String) -> String? {
        let prefix = "mcp:"
        guard toolID.hasPrefix(prefix) else { return nil }
        let remainder = toolID.dropFirst(prefix.count)
        guard let separator = remainder.firstIndex(of: ":") else { return nil }
        let serverID = String(remainder[..<separator])
        let encodedName = String(remainder[remainder.index(after: separator)...])
        guard !serverID.isEmpty, !encodedName.isEmpty else { return nil }
        let standardBase64 = encodedName
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = String(repeating: "=", count: (4 - standardBase64.count % 4) % 4)
        guard let nameData = Data(base64Encoded: standardBase64 + padding),
              let name = String(data: nameData, encoding: .utf8),
              !name.isEmpty,
              self.toolID(serverID: serverID, toolName: name) == toolID else { return nil }
        return serverID
    }

    func prepare(callID: String, argumentsJSON: String) throws -> ToolExecutionIntent {
        let object = try ToolArgumentJSON.object(from: argumentsJSON)
        let normalized = try ToolArgumentJSON.normalizedObject(object)
        return try ToolIntentCodec.freeze(
            descriptor: descriptor,
            actionID: Self.actionID,
            normalizedArgumentsJSON: normalized,
            resource: .notRequired,
            destination: .mcpServer(serverID: server.id, endpointIdentity: endpointIdentity),
            approvalDisclosure: ToolApprovalDisclosure(
                toolDisplayName: descriptor.displayName,
                action: "调用 MCP 工具 \(definition.name)",
                targetDescription: "\(server.displayName) · \(connection.serverInfo?.name ?? server.displayName)",
                keyImpact: "将向此 MCP 服务发送工具调用及其参数。"
            )
        )
    }

    func validateDependencies(_ intent: ToolExecutionIntent) throws {
        try ToolIntentCodec.validate(intent, descriptor: descriptor)
        guard intent.destinationScope == .mcpServer(
            serverID: server.id,
            endpointIdentity: endpointIdentity
        ) else {
            throw ToolIntentFailure.dependenciesChanged
        }
    }

    func validateLiveDependencies(_ intent: ToolExecutionIntent) async throws {
        try validateDependencies(intent)
        guard connection.isAvailable() else {
            throw ToolIntentFailure.dependenciesChanged
        }
        _ = try connection.authentication?.resolve()
    }

    func execute(_ intent: ToolExecutionIntent, idempotencyKey: String) async throws -> ToolExecutionResult {
        try validateDependencies(intent)
        let arguments = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: Data(intent.normalizedArgumentsJSON.utf8)
        )
        let result = try await connection.callTool(definition, arguments: arguments)
        if result.isError {
            return ToolExecutionResult(
                content: result.displayContent,
                kind: .error,
                failure: .executionFailed
            )
        }
        return ToolExecutionResult(content: result.displayContent)
    }

    private static func makeDescriptor(
        server: MCPServer,
        connection: MCPConnection,
        definition: MCPToolDefinition,
        endpointIdentity: String
    ) -> ToolDescriptor {
        let id = toolID(serverID: server.id, toolName: definition.name)
        let revision = descriptorRevision(
            server: server,
            serverInfo: connection.serverInfo,
            definition: definition,
            endpointIdentity: endpointIdentity,
            authenticationIdentity: connection.authenticationIdentity
        )
        let action = ToolPolicyActionMetadata(
            toolID: id,
            actionID: actionID,
            descriptorRevision: revision,
            risk: .high,
            allowsAutomaticApproval: false,
            allowsConversationGrant: false,
            resourceRequirement: .notRequired,
            egressRequirement: .mcpServerRequiringApproval
        )
        let displayName = "\(server.displayName) · \(definition.title ?? definition.name)"
        return ToolDescriptor(
            id: id,
            displayName: displayName,
            description: definition.description ?? "MCP tool \(definition.name)",
            inputSchema: definition.inputSchema,
            revision: revision,
            sideEffect: .externalWrite,
            approvalRequirement: .required,
            actions: [action]
        )
    }

    private static func descriptorRevision(
        server: MCPServer,
        serverInfo: MCPServerInfo?,
        definition: MCPToolDefinition,
        endpointIdentity: String,
        authenticationIdentity: String?
    ) -> String {
        struct RevisionInput: Encodable {
            let serverID: String
            let endpointIdentity: String
            let authenticationReference: MCPAuthenticationReference?
            let authenticationIdentity: String?
            let serverInfo: MCPServerInfo?
            let definition: MCPToolDefinition
        }
        let input = RevisionInput(
            serverID: server.id,
            endpointIdentity: endpointIdentity,
            authenticationReference: server.authenticationReference,
            authenticationIdentity: authenticationIdentity,
            serverInfo: serverInfo,
            definition: definition
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(input) else {
            preconditionFailure("MCP tool revision inputs are Codable JSON values")
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "mcp-tool-v1:\(digest)"
    }
}

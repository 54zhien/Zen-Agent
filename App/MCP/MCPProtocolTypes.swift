import Foundation
import CryptoKit

enum MCPAuthenticationReference: Codable, Sendable, Equatable {
    case credential(CredentialReference)
    case globalEnvironment(EnvironmentRevisionReference)
}

struct MCPAuthenticationResolver: Sendable {
    let reference: MCPAuthenticationReference?
    let store: PersistenceStore
    let credentials: any CredentialStoring
    let bindingGeneration: Int?

    init(
        reference: MCPAuthenticationReference?,
        store: PersistenceStore,
        credentials: any CredentialStoring
    ) throws {
        self.reference = reference
        self.store = store
        self.credentials = credentials

        switch reference {
        case .none:
            bindingGeneration = nil
        case .some(.credential(let credential)):
            guard let metadata = try credentials.metadata(for: credential),
                  metadata.status == .active else {
                throw MCPClientError.authenticationRequired
            }
            bindingGeneration = metadata.bindingGeneration
        case .some(.globalEnvironment(let environmentReference)):
            guard let environment = try store.environmentVariables().first(where: {
                $0.id == environmentReference.variableID
            }),
                  environment.reference == environmentReference,
                  environment.scope == .global,
                  !environment.pendingDeletion,
                  case .secret(let binding) = environment.value,
                  let metadata = try credentials.metadata(for: binding.reference),
                  metadata.reference == binding.reference,
                  metadata.status == .active,
                  metadata.bindingGeneration == binding.generation else {
                throw MCPClientError.authenticationRequired
            }
            bindingGeneration = binding.generation
        }
    }

    var identity: String? {
        guard let reference, let bindingGeneration else { return nil }
        switch reference {
        case .credential(let credential):
            "credential:\(credential.kind.rawValue):\(credential.id):\(bindingGeneration)"
        case .globalEnvironment(let environment):
            "globalEnvironment:\(environment.variableID):\(environment.revisionID):\(bindingGeneration)"
        }
    }

    func validate() throws {
        _ = try resolve()
    }

    func resolve() throws -> SecretValue? {
        guard let reference else { return nil }
        switch reference {
        case .credential(let credential):
            guard let bindingGeneration,
                  let metadata = try credentials.metadata(for: credential),
                  metadata.status == .active,
                  metadata.bindingGeneration == bindingGeneration,
                  let secret = try credentials.resolve(
                    frozenReference: credential,
                    generation: bindingGeneration
                  ) else {
                throw MCPClientError.authenticationRequired
            }
            return secret
        case .globalEnvironment(let environmentReference):
            guard let environment = try store.environmentVariables().first(where: {
                $0.id == environmentReference.variableID
            }),
                  environment.reference == environmentReference,
                  environment.scope == .global,
                  !environment.pendingDeletion,
                  case .secret(let binding) = environment.value,
                  let bindingGeneration,
                  binding.generation == bindingGeneration,
                  let metadata = try credentials.metadata(for: binding.reference),
                  metadata.status == .active,
                  metadata.bindingGeneration == binding.generation,
                  let secret = try credentials.resolve(
                    frozenReference: binding.reference,
                    generation: binding.generation
                  ) else {
                throw MCPClientError.authenticationRequired
            }
            return secret
        }
    }
}

struct MCPServerInfo: Codable, Sendable, Equatable {
    let name: String
    let version: String
}

struct MCPServerDependencyIdentity: Codable, Sendable, Equatable, Hashable {
    let serverID: String
    let endpointIdentity: String
    let authenticationIdentity: String?
}

enum MCPServerEndpointIdentity {
    static func canonicalString(_ endpoint: URL) -> String {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return endpoint.absoluteString
        }
        let scheme = components.scheme?.lowercased() ?? ""
        components.scheme = scheme
        components.host = components.host?.lowercased()
        if (scheme == "https" && components.port == 443)
            || (scheme == "http" && components.port == 80) {
            components.port = nil
        }
        if components.percentEncodedPath.isEmpty { components.percentEncodedPath = "/" }
        components.fragment = nil
        return components.string ?? endpoint.absoluteString
    }

    static func digest(_ endpoint: URL) -> String {
        SHA256.hash(data: Data(canonicalString(endpoint).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct MCPToolAnnotations: Codable, Sendable, Equatable {
    let readOnlyHint: Bool?
    let destructiveHint: Bool?
    let idempotentHint: Bool?
    let openWorldHint: Bool?
}

struct MCPToolDefinition: Codable, Sendable, Equatable, Identifiable {
    let name: String
    let title: String?
    let description: String?
    let inputSchema: JSONValue
    let outputSchema: JSONValue?
    let annotations: MCPToolAnnotations?

    var id: String { name }
}

struct MCPResourceDefinition: Codable, Sendable, Equatable, Identifiable {
    let uri: String
    let name: String
    let title: String?
    let description: String?
    let mimeType: String?

    var id: String { uri }
}

struct MCPPromptDefinition: Codable, Sendable, Equatable, Identifiable {
    let name: String
    let title: String?
    let description: String?

    var id: String { name }
}

struct MCPServerConnectionSnapshot: Sendable, Equatable, Identifiable {
    let serverID: String
    let state: MCPServerConnectionState
    let lastError: String?
    let serverInfo: MCPServerInfo?
    let tools: [MCPToolDefinition]
    let resources: [MCPResourceDefinition]
    let prompts: [MCPPromptDefinition]
    let toolDescriptors: [ToolDescriptor]

    var id: String { serverID }
    var capabilitySummary: String {
        "\(tools.count) Tools · \(resources.count) Resources · \(prompts.count) Prompts"
    }

    static func configuration(server: MCPServer) -> Self {
        Self(
            serverID: server.id,
            state: server.enabled ? .disconnected : .disabled,
            lastError: nil,
            serverInfo: nil,
            tools: [],
            resources: [],
            prompts: [],
            toolDescriptors: []
        )
    }
}

enum MCPClientError: Error, Sendable, Equatable {
    case invalidEndpoint
    case unsupportedProtocol([String])
    case httpStatus(Int)
    case rpcError(code: Int, message: String)
    case invalidResponse
    case connectionUnavailable
    case serverConfigurationChanged
    case authenticationRequired
}

struct MCPToolCallResult: Sendable, Equatable {
    let content: [JSONValue]
    let structuredContent: JSONValue?
    let isError: Bool

    var displayContent: String {
        if let structuredContent,
           let data = try? JSONEncoder().encode(structuredContent),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        let textBlocks = content.compactMap { value -> String? in
            guard case .object(let object) = value,
                  case .string("text") = object["type"],
                  case .string(let text) = object["text"] else { return nil }
            return text
        }
        if !textBlocks.isEmpty { return textBlocks.joined(separator: "\n") }
        guard let data = try? JSONEncoder().encode(JSONValue.array(content)),
              let string = String(data: data, encoding: .utf8) else { return "" }
        return string
    }
}

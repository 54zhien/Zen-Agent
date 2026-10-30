import Foundation

enum ToolSideEffect: String, Codable, Sendable {
    case none
    case externalWrite
}

enum ToolApprovalRequirement: String, Codable, Sendable {
    case notRequired
    case required
}

/// User-readable details frozen with a prepared tool call for later approval.
struct ToolApprovalDisclosure: Codable, Sendable, Equatable {
    let toolDisplayName: String
    let action: String
    let targetDescription: String
    let keyImpact: String

    var isComplete: Bool {
        [toolDisplayName, action, targetDescription, keyImpact]
            .allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

struct ToolDescriptor: Sendable, Equatable {
    var id: String
    var displayName: String
    var description: String
    var inputSchema: JSONValue
    var revision: String
    var sideEffect: ToolSideEffect
    var approvalRequirement: ToolApprovalRequirement
    var actions: [ToolPolicyActionMetadata] = []
}

struct ToolExecutionIntent: Codable, Sendable, Equatable {
    static let currentFormatVersion = 2

    var formatVersion: Int
    var toolID: String
    var descriptorRevision: String
    var normalizedArgumentsJSON: String
    var targetIdentity: String?
    var destinationIdentity: String?
    var approvalDisclosure: ToolApprovalDisclosure? = nil
    var policyAction: ToolPolicyActionMetadata? = nil
    var resourceScope: ToolResourceScope? = nil
    var destinationScope: ToolDestinationScope? = nil
}

struct ToolExecutionResult: Sendable, Equatable {
    var content: String
    var kind: ToolResultKind = .text
    var failure: ToolResultFailure? = nil

    static func failure(_ code: ToolResultFailure) -> Self {
        Self(content: "Tool result: \(code.rawValue).", kind: .error, failure: code)
    }
}

protocol ToolExecutable: Sendable {
    var descriptor: ToolDescriptor { get }

    func prepare(
        callID: String,
        argumentsJSON: String
    ) throws -> ToolExecutionIntent

    func execute(
        _ intent: ToolExecutionIntent,
        idempotencyKey: String
    ) async throws -> ToolExecutionResult

    func prepare(callID: String, argumentsJSON: String, context: ToolPreparationContext) throws -> ToolExecutionIntent
    func validateDependencies(_ intent: ToolExecutionIntent, context: ToolPreparationContext) throws

    /// Trusted dependency check; may reject, never replace the frozen intent.
    func validateDependencies(_ intent: ToolExecutionIntent) throws
    func validateLiveDependencies(_ intent: ToolExecutionIntent) async throws
}

extension ToolExecutable {
    func prepare(callID: String, argumentsJSON: String, context: ToolPreparationContext) throws -> ToolExecutionIntent {
        try prepare(callID: callID, argumentsJSON: argumentsJSON)
    }
    func validateDependencies(_ intent: ToolExecutionIntent, context: ToolPreparationContext) throws {
        try validateDependencies(intent)
    }
    func validateDependencies(_ intent: ToolExecutionIntent) throws {
        // A scoped executor must supply a trusted live resolver. Only stateless
        // actions can prove their lack of mutable dependencies without one.
        guard intent.resourceScope == .notRequired, intent.destinationScope == .notRequired else {
            throw ToolIntentFailure.dependenciesChanged
        }
    }
    func validateLiveDependencies(_ intent: ToolExecutionIntent) async throws {
        try validateDependencies(intent)
    }
}

enum ToolRegistryError: Error, Equatable, Sendable {
    case duplicateToolID(String)
}

enum ToolExecutionError: Error, Equatable, Sendable {
    case invalidArguments
    case invalidExpression
    case divisionByZero
    case invalidIntent
}

struct ToolRegistry: Sendable {
    private let executorsByID: [String: any ToolExecutable]
    let descriptors: [ToolDescriptor]

    static let empty: ToolRegistry = {
        // The empty registry is the safe default for callers that have not exposed a
        // tool surface yet. Stage 2 callers can still inject an explicit registry.
        try! ToolRegistry(tools: [])
    }()

    init(tools: [any ToolExecutable]) throws {
        var executorsByID: [String: any ToolExecutable] = [:]
        var descriptors: [ToolDescriptor] = []
        descriptors.reserveCapacity(tools.count)

        for tool in tools {
            let descriptor = tool.descriptor
            guard executorsByID[descriptor.id] == nil else {
                throw ToolRegistryError.duplicateToolID(descriptor.id)
            }

            executorsByID[descriptor.id] = tool
            descriptors.append(descriptor)
        }

        self.executorsByID = executorsByID
        self.descriptors = descriptors
    }

    func descriptor(id: String) -> ToolDescriptor? {
        descriptors.first { $0.id == id }
    }

    func executor(id: String) -> (any ToolExecutable)? {
        executorsByID[id]
    }

    func merging(_ additionalExecutables: [any ToolExecutable]) throws -> ToolRegistry {
        let existing = descriptors.compactMap { executorsByID[$0.id] }
        return try ToolRegistry(tools: existing + additionalExecutables)
    }

    func filteringExecutables(_ include: (any ToolExecutable) -> Bool) throws -> ToolRegistry {
        try ToolRegistry(tools: descriptors.compactMap { executorsByID[$0.id] }.filter(include))
    }

    var mcpServerIDs: Set<String> {
        Set(descriptors.compactMap { MCPToolExecutable.serverID(forToolID: $0.id) })
    }

    var mcpServerDependencyIdentities: [String: MCPServerDependencyIdentity] {
        var identities: [String: MCPServerDependencyIdentity] = [:]
        for descriptor in descriptors {
            guard let executable = executorsByID[descriptor.id] as? MCPToolExecutable else { continue }
            identities[executable.server.id] = MCPServerDependencyIdentity(
                serverID: executable.server.id,
                endpointIdentity: executable.connection.endpointIdentity,
                authenticationIdentity: executable.connection.authenticationIdentity
            )
        }
        return identities
    }
}

struct ToolRuntimeRegistryContext: Sendable {
    let registry: ToolRegistry
    let availableMCPServerIDs: Set<String>
    let availableMCPServerIdentities: [String: MCPServerDependencyIdentity]

    init(
        registry: ToolRegistry,
        availableMCPServerIDs: Set<String>? = nil,
        availableMCPServerIdentities: [String: MCPServerDependencyIdentity]? = nil
    ) {
        self.registry = registry
        let identities = availableMCPServerIdentities ?? registry.mcpServerDependencyIdentities
        let serverIDs = availableMCPServerIDs ?? Set(identities.keys)
        self.availableMCPServerIDs = serverIDs
        self.availableMCPServerIdentities = identities.filter { serverIDs.contains($0.key) }
    }
}

enum ToolArgumentJSON {
    static func object(from argumentsJSON: String) throws -> [String: Any] {
        guard let data = argumentsJSON.data(using: .utf8) else {
            throw ToolExecutionError.invalidArguments
        }

        do {
            guard let object = try JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
            ) as? [String: Any] else {
                throw ToolExecutionError.invalidArguments
            }
            return object
        } catch let error as ToolExecutionError {
            throw error
        } catch {
            throw ToolExecutionError.invalidArguments
        }
    }

    static func normalizedObject(_ object: [String: Any]) throws -> String {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ToolExecutionError.invalidArguments
        }

        do {
            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
            guard let result = String(data: data, encoding: .utf8) else {
                throw ToolExecutionError.invalidArguments
            }
            return result
        } catch let error as ToolExecutionError {
            throw error
        } catch {
            throw ToolExecutionError.invalidArguments
        }
    }

    static func requireEmptyObject(_ argumentsJSON: String) throws {
        let object = try object(from: argumentsJSON)
        guard object.isEmpty else {
            throw ToolExecutionError.invalidArguments
        }
    }
}

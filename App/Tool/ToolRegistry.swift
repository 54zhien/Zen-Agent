import Foundation

enum ToolSideEffect: String, Codable, Sendable {
    case none
    case externalWrite
}

enum ToolApprovalRequirement: String, Codable, Sendable {
    case notRequired
    case required
}

struct ToolDescriptor: Sendable, Equatable {
    var id: String
    var displayName: String
    var description: String
    var inputSchema: JSONValue
    var revision: String
    var sideEffect: ToolSideEffect
    var approvalRequirement: ToolApprovalRequirement
}

struct ToolExecutionIntent: Codable, Sendable, Equatable {
    static let currentFormatVersion = 1

    var formatVersion: Int
    var toolID: String
    var descriptorRevision: String
    var normalizedArgumentsJSON: String
    var targetIdentity: String?
    var destinationIdentity: String?
}

struct ToolExecutionResult: Sendable, Equatable {
    var content: String
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

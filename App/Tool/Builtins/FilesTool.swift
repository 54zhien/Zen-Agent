import Foundation

/// Managed FileAsset access. Conservative boundary until the native read contracts
/// are implemented; arbitrary model paths never become sandbox authority.
struct FilesTool: ToolExecutable {
    let files: ManagedFileStore
    let store: PersistenceStore
    var descriptor: ToolDescriptor {
        ToolDescriptor(id: "files", displayName: "Files", description: "Read a managed UTF-8 text file by FileAsset identity.",
            inputSchema: .object(["type": .string("object"), "properties": .object(["assetID": .object(["type": .string("string")])]), "required": .array([.string("assetID")]), "additionalProperties": .bool(false)]),
            revision: "1", sideEffect: .none, approvalRequirement: .required,
            actions: [.init(toolID: "files", actionID: "read", descriptorRevision: "1", risk: .low,
                allowsAutomaticApproval: true, allowsConversationGrant: true, resourceRequirement: .file,
                egressRequirement: .providerRequiringApproval)])
    }
    func prepare(callID: String, argumentsJSON: String) throws -> ToolExecutionIntent { throw ToolIntentFailure.preparationFailed }
    func prepare(callID: String, argumentsJSON: String, context: ToolPreparationContext) throws -> ToolExecutionIntent { throw ToolIntentFailure.preparationFailed }
    func execute(_ intent: ToolExecutionIntent, idempotencyKey: String) async throws -> ToolExecutionResult { throw ToolIntentFailure.dependenciesChanged }
}

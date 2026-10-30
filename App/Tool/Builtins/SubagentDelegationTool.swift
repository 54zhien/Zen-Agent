import Foundation

struct SubagentDelegationTool: DelegatedToolOutcomeConfirming, DelegatedToolRecoveryResuming {
    static let toolID = "subagent"
    static let actionID = "delegate"
    static let descriptorRevision = "2"

    static let toolDescriptor = ToolDescriptor(
        id: toolID,
        displayName: "Subagent",
        description: "Ask one isolated child run to complete a task, using only tools and context allowed by the Parent. Explicitly name Environment keys to share.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "task": .object(["type": .string("string")]),
                "environmentKeys": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "uniqueItems": .bool(true),
                    "maxItems": .number(64),
                ]),
            ]),
            "required": .array([.string("task")]),
            "additionalProperties": .bool(false),
        ]),
        revision: descriptorRevision,
        sideEffect: .externalWrite,
        approvalRequirement: .required,
        actions: [ToolPolicyActionMetadata(
            toolID: toolID,
            actionID: actionID,
            descriptorRevision: descriptorRevision,
            risk: .high,
            allowsAutomaticApproval: false,
            allowsConversationGrant: false,
            resourceRequirement: .target,
            egressRequirement: .providerRequiringApproval
        )]
    )

    let parentRunID: String
    let store: PersistenceStore
    let delegationRuntime: DelegationRuntime

    var descriptor: ToolDescriptor { Self.toolDescriptor }

    func prepare(callID: String, argumentsJSON: String) throws -> ToolExecutionIntent {
        try prepare(callID: callID, argumentsJSON: argumentsJSON,
            context: ToolPreparationContext(requestConfigSeed: try parentRun().requestConfigSeed))
    }

    func prepare(
        callID: String,
        argumentsJSON: String,
        context: ToolPreparationContext
    ) throws -> ToolExecutionIntent {
        _ = callID
        let arguments = try Self.arguments(from: argumentsJSON)
        if !arguments.environmentKeys.isEmpty {
            guard Set(arguments.environmentKeys).isSubset(of: try parentFrozenEnvironmentKeys()) else {
                throw ToolExecutionError.invalidArguments
            }
        }

        return try ToolIntentCodec.freeze(
            descriptor: descriptor,
            actionID: Self.actionID,
            normalizedArgumentsJSON: ToolArgumentJSON.normalizedObject([
                "task": arguments.task,
                "environmentKeys": arguments.environmentKeys,
            ]),
            resource: .target(parentRunID),
            destination: context.destination,
            approvalDisclosure: ToolApprovalDisclosure(
                toolDisplayName: descriptor.displayName,
                action: "Start one child model run",
                targetDescription: "Parent Run \(parentRunID)",
                keyImpact: arguments.environmentKeys.isEmpty
                    ? "Child tools are limited to the Parent's frozen tools. Environment keys: none. Its result returns to the current model."
                    : "Child tools are limited to the Parent's frozen tools. Requested Environment keys: \(arguments.environmentKeys.joined(separator: ", ")). Its result returns to the current model."
            )
        )
    }

    func validateDependencies(_ intent: ToolExecutionIntent, context: ToolPreparationContext) throws {
        try validate(intent)
        guard intent.resourceScope == .target(parentRunID),
              intent.destinationScope == context.destination,
              try parentAllowsDelegation()
        else { throw ToolIntentFailure.dependenciesChanged }
    }

    func validateDependencies(_ intent: ToolExecutionIntent) throws {
        try validate(intent)
        guard intent.resourceScope == .target(parentRunID),
              intent.destinationScope == ToolPreparationContext(
                requestConfigSeed: try parentRun().requestConfigSeed
              ).destination,
              try parentAllowsDelegation()
        else { throw ToolIntentFailure.dependenciesChanged }
    }

    func validateLiveDependencies(_ intent: ToolExecutionIntent) async throws {
        try validateDependencies(intent)
        guard let parent = try store.run(id: parentRunID), parent.state == .executingTools else {
            throw ToolIntentFailure.dependenciesChanged
        }
    }

    func execute(
        _ intent: ToolExecutionIntent,
        idempotencyKey: String
    ) async throws -> ToolExecutionResult {
        try validate(intent)
        let arguments = try Self.arguments(from: intent.normalizedArgumentsJSON)
        return try await delegationRuntime.execute(
            parentRunID: parentRunID,
            parentToolCallID: idempotencyKey,
            task: arguments.task,
            environmentKeys: arguments.environmentKeys
        )
    }

    func confirmedResult(_ intent: ToolExecutionIntent, idempotencyKey: String) throws -> ToolExecutionResult? {
        do { try ToolIntentCodec.validate(intent, descriptor: descriptor) }
        catch { return nil }
        guard let call = try store.toolCall(id: idempotencyKey),
              call.agentRunID == parentRunID,
              call.action == Self.toolID,
              let encodedIntent = call.executionIntent,
              let parent = try store.run(id: parentRunID),
              parent.state == .executingTools || parent.state == .recovering || parent.state == .stopping
        else { return nil }
        return try store.delegatedToolOutcome(
            parentToolCallID: idempotencyKey,
            attempt: call.attempt,
            intentBinding: ToolIntentBinding.make(encodedIntent),
            expectedParentState: parent.state
        )
    }

    func persistConfirmedResult(
        _ result: ToolExecutionResult,
        observedResult: ToolExecutionResult,
        intent: ToolExecutionIntent,
        idempotencyKey: String
    ) throws -> Bool {
        try ToolIntentCodec.validate(intent, descriptor: descriptor)
        guard let call = try store.toolCall(id: idempotencyKey),
              call.agentRunID == parentRunID,
              call.action == Self.toolID,
              let encodedIntent = call.executionIntent,
              let parent = try store.run(id: parentRunID),
              parent.state == .executingTools || parent.state == .recovering || parent.state == .stopping
        else { return false }
        return try store.confirmDelegatedToolOutcome(
            parentToolCallID: idempotencyKey,
            attempt: call.attempt,
            intentBinding: ToolIntentBinding.make(encodedIntent),
            expectedParentState: parent.state,
            observedOutcome: observedResult,
            result: result
        )
    }

    func resumeDispatchedChild(
        _ intent: ToolExecutionIntent,
        idempotencyKey: String
    ) async throws {
        try validate(intent)
        let arguments = try Self.arguments(from: intent.normalizedArgumentsJSON)
        _ = try await delegationRuntime.resumeDispatchedChild(
            parentRunID: parentRunID,
            parentToolCallID: idempotencyKey,
            task: arguments.task,
            environmentKeys: arguments.environmentKeys
        )
    }

    func failUnknownChildren(parentRunID: String) throws {
        guard parentRunID == self.parentRunID else {
            throw DelegationRuntimeError.invalidParent(parentRunID)
        }
        try store.failUnknownDelegatedChildren(
            parentRunID: parentRunID,
            endReason: .streamInterrupted
        )
    }

    private func parentRun() throws -> AgentRunRecord {
        guard let run = try store.run(id: parentRunID),
              run.kind == .parent,
              run.parentRunID == nil
        else { throw ToolIntentFailure.dependenciesChanged }
        return run
    }

    private func validate(_ intent: ToolExecutionIntent) throws {
        try ToolIntentCodec.validate(intent, descriptor: descriptor)
        guard intent.resourceScope == .target(parentRunID) else {
            throw ToolExecutionError.invalidIntent
        }
        let arguments = try Self.arguments(from: intent.normalizedArgumentsJSON)
        if !arguments.environmentKeys.isEmpty {
            guard Set(arguments.environmentKeys).isSubset(of: try parentFrozenEnvironmentKeys()) else {
                throw ToolIntentFailure.dependenciesChanged
            }
        }
    }

    private func parentFrozenEnvironmentKeys() throws -> Set<String> {
        guard let snapshotJSON = try parentRun().executionSnapshot,
              let snapshot = try? ExecutionSnapshotCodec.decode(snapshotJSON)
        else { throw ToolIntentFailure.dependenciesChanged }
        let references = Array(Set(snapshot.prompt.skillReferences.flatMap(\.environmentReferences)))
            .sorted {
                if $0.variableID != $1.variableID { return $0.variableID < $1.variableID }
                return $0.revisionID < $1.revisionID
            }
        return Set(try store.resolveEnvironmentReferences(references).map(\.key))
    }

    private static func arguments(from json: String) throws -> (task: String, environmentKeys: [String]) {
        let object = try ToolArgumentJSON.object(from: json)
        guard object.keys.allSatisfy({ $0 == "task" || $0 == "environmentKeys" }),
              let task = object["task"] as? String,
              !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw ToolExecutionError.invalidArguments }

        let environmentKeys: [String]
        if let rawKeys = object["environmentKeys"] {
            guard let parsedKeys = rawKeys as? [String] else { throw ToolExecutionError.invalidArguments }
            environmentKeys = parsedKeys
        } else {
            environmentKeys = []
        }
        guard environmentKeys.count <= 64,
              Set(environmentKeys).count == environmentKeys.count,
              environmentKeys.allSatisfy(EnvironmentValidation.allowsKey)
        else { throw ToolExecutionError.invalidArguments }
        return (task, environmentKeys.sorted())
    }

    private func parentAllowsDelegation() throws -> Bool {
        guard let encoded = try parentRun().executionSnapshot,
              let snapshot = try? ExecutionSnapshotCodec.decode(encoded),
              let policy = snapshot.delegation
        else { return false }
        return policy.enabled
            && policy.maxDepth == 1
            && policy.supportsFrozenConcurrencyLimit
            && policy.modelPolicy == .followParent
            && policy.environmentInheritance == .none
            && snapshot.permitsTool(descriptor)
    }
}

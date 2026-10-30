import Foundation

struct SubagentDelegationTool: DelegatedToolOutcomeConfirming, DelegatedToolRecoveryResuming {
    static let toolID = "subagent"
    static let actionID = "delegate"
    static let descriptorRevision = "1"

    static let toolDescriptor = ToolDescriptor(
        id: toolID,
        displayName: "Subagent",
        description: "Ask one isolated child run to complete a task, then return its result.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "task": .object(["type": .string("string")]),
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
        let object = try ToolArgumentJSON.object(from: argumentsJSON)
        guard object.count == 1,
              let task = object["task"] as? String,
              !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw ToolExecutionError.invalidArguments }

        return try ToolIntentCodec.freeze(
            descriptor: descriptor,
            actionID: Self.actionID,
            normalizedArgumentsJSON: ToolArgumentJSON.normalizedObject(["task": task]),
            resource: .target(parentRunID),
            destination: context.destination,
            approvalDisclosure: ToolApprovalDisclosure(
                toolDisplayName: descriptor.displayName,
                action: "Start one child model run",
                targetDescription: "Parent Run \(parentRunID)",
                keyImpact: "The child receives only this task and no tools or inherited Environment values. Its result returns to the current model."
            )
        )
    }

    func validateDependencies(_ intent: ToolExecutionIntent, context: ToolPreparationContext) throws {
        try ToolIntentCodec.validate(intent, descriptor: descriptor)
        guard intent.resourceScope == .target(parentRunID),
              intent.destinationScope == context.destination,
              try parentAllowsDelegation()
        else { throw ToolIntentFailure.dependenciesChanged }
    }

    func validateDependencies(_ intent: ToolExecutionIntent) throws {
        try ToolIntentCodec.validate(intent, descriptor: descriptor)
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
        try ToolIntentCodec.validate(intent, descriptor: descriptor)
        guard intent.resourceScope == .target(parentRunID),
              let object = try? ToolArgumentJSON.object(from: intent.normalizedArgumentsJSON),
              let task = object["task"] as? String
        else { throw ToolExecutionError.invalidIntent }
        return try await delegationRuntime.execute(
            parentRunID: parentRunID,
            parentToolCallID: idempotencyKey,
            task: task
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
              parent.state == .recovering || parent.state == .stopping
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
              parent.state == .recovering || parent.state == .stopping
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

    func resumeUnstartedChild(
        _ intent: ToolExecutionIntent,
        idempotencyKey: String
    ) async throws {
        try ToolIntentCodec.validate(intent, descriptor: descriptor)
        guard let object = try? ToolArgumentJSON.object(from: intent.normalizedArgumentsJSON),
              let task = object["task"] as? String
        else { throw ToolExecutionError.invalidIntent }
        try await delegationRuntime.resumeUnstartedChild(
            parentRunID: parentRunID,
            parentToolCallID: idempotencyKey,
            task: task
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

    private func parentAllowsDelegation() throws -> Bool {
        guard let encoded = try parentRun().executionSnapshot,
              let snapshot = try? ExecutionSnapshotCodec.decode(encoded),
              let policy = snapshot.delegation
        else { return false }
        return policy.enabled
            && policy.maxDepth == 1
            && policy.maxConcurrentChildren == 1
            && policy.modelPolicy == .followParent
            && policy.environmentInheritance == .none
            && snapshot.permitsTool(descriptor)
    }
}

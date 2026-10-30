import Foundation

enum DelegationRuntimeError: Error, Sendable {
    case invalidParent(String)
    case invalidToolCall(String)
    case unavailableParentPolicy
    case unavailableChildOutcome(String)
    case unsupportedChildState(String, RunState)
}

/// Owns the Child Run lifecycle for one Parent ToolCall. ConversationRuntime still
/// owns event projection; AgentRuntime owns run execution and transitions; the store
/// owns the stable Parent ToolCall-to-Child identity.
actor DelegationRuntime {
    private let store: PersistenceStore
    private let provider: any ModelProvider
    private let agentRuntime: AgentRuntime
    private let project: AgentEventProjection

    init(
        store: PersistenceStore,
        provider: any ModelProvider,
        agentRuntime: AgentRuntime,
        project: @escaping AgentEventProjection
    ) {
        self.store = store
        self.provider = provider
        self.agentRuntime = agentRuntime
        self.project = project
    }

    func execute(
        parentRunID: String,
        parentToolCallID: String,
        task: String
    ) async throws -> ToolExecutionResult {
        guard !Task.isCancelled else { throw CancellationError() }
        let parent = try requiredParent(id: parentRunID)
        guard parent.state == .executingTools else {
            throw DelegationRuntimeError.invalidParent(parentRunID)
        }
        let call = try requiredDelegationCall(id: parentToolCallID, parentRunID: parentRunID)
        guard call.state == .dispatched else {
            throw DelegationRuntimeError.invalidToolCall(parentToolCallID)
        }
        let parentSnapshot = try enabledParentSnapshot(parent)
        let child = try prepareChild(
            parent: parent,
            parentSnapshot: parentSnapshot,
            parentToolCallID: parentToolCallID
        )
        if child.state.isTerminal {
            guard let result = try store.delegatedChildOutcome(runID: child.id) else {
                throw DelegationRuntimeError.unavailableChildOutcome(child.id)
            }
            return result
        }
        guard child.state == .preparing || child.state == .requestingModel,
              try store.steps(inRun: child.id).isEmpty
        else {
            throw CancellationError()
        }
        return try await runChild(
            child: child,
            parent: parent,
            parentSnapshot: parentSnapshot,
            task: task
        )
    }

    /// Called only after RunRecovery has durably recorded the Parent's recovery action.
    /// A Child with no persisted provider Step has not crossed the provider dispatch
    /// boundary, so the same Parent ToolCall may resume that stable Child identity.
    func resumeUnstartedChild(
        parentRunID: String,
        parentToolCallID: String,
        task: String
    ) async throws {
        guard let parent = try store.run(id: parentRunID),
              parent.kind == .parent,
              parent.state == .recovering,
              parent.recoveryAction == .resume
        else { return }

        let call = try requiredDelegationCall(id: parentToolCallID, parentRunID: parentRunID)
        guard call.state == .dispatched || call.state == .indeterminate else { return }
        let parentSnapshot = try enabledParentSnapshot(parent)
        let child = try prepareChild(
            parent: parent,
            parentSnapshot: parentSnapshot,
            parentToolCallID: parentToolCallID
        )
        guard !child.state.isTerminal,
              (child.state == .preparing || child.state == .requestingModel),
              try store.steps(inRun: child.id).isEmpty
        else { return }
        _ = try await runChild(
            child: child,
            parent: parent,
            parentSnapshot: parentSnapshot,
            task: task
        )
    }

    private func runChild(
        child: AgentRunRecord,
        parent: AgentRunRecord,
        parentSnapshot: RunExecutionSnapshot,
        task: String
    ) async throws -> ToolExecutionResult {
        guard let currentParent = try store.run(id: parent.id),
              currentParent.state == .executingTools ||
                (currentParent.state == .recovering && currentParent.recoveryAction == .resume)
        else { throw CancellationError() }
        guard let encoded = child.executionSnapshot else {
            throw DelegationRuntimeError.unavailableParentPolicy
        }
        let childSnapshot = try ExecutionSnapshotCodec.decode(encoded)
        guard childSnapshot.delegation == nil,
              childSnapshot.exposedTools.isEmpty,
              !childSnapshot.modelCapabilities.contains(.tools),
              childSnapshot.prompt.memoryReferences.isEmpty,
              childSnapshot.prompt.skillReferences.isEmpty,
              childSnapshot.mcpServerDependencies.isEmpty
        else { throw DelegationRuntimeError.unavailableParentPolicy }

        let sections = try PromptTemplateCatalog.resolve(
            runtimeSafetyRevision: childSnapshot.prompt.runtimeSafetyBaseline,
            zenCoreRevision: childSnapshot.prompt.zenCore
        )
        let request = PromptComposer().compose(PromptCompositionInput(
            modelID: child.requestConfigSeed.modelID,
            providerAdapterInstructions: childSnapshot.prompt.providerAdapterInstructions,
            history: [],
            currentUserMessage: task,
            tools: [],
            systemSections: sections
        ))

        await agentRuntime.bindToolRegistry(
            ToolRuntimeRegistryContext(registry: .empty),
            forRunID: child.id
        )
        let stream = await agentRuntime.advance(
            runID: child.id,
            request: request,
            snapshot: childSnapshot,
            project: project
        )
        let childExecution = Task<ToolExecutionResult, Error> {
            do {
                for try await _ in stream { }
            } catch {
                if let result = try store.delegatedChildOutcome(runID: child.id) {
                    return result
                }
                throw error
            }
            guard let result = try store.delegatedChildOutcome(runID: child.id) else {
                throw DelegationRuntimeError.unavailableChildOutcome(child.id)
            }
            return result
        }

        return try await withTaskCancellationHandler {
            try await childExecution.value
        } onCancel: {
            Task { await self.cancelChild(child.id, parentRunID: parent.id) }
        }
    }

    private func prepareChild(
        parent: AgentRunRecord,
        parentSnapshot: RunExecutionSnapshot,
        parentToolCallID: String
    ) throws -> AgentRunRecord {
        let childSnapshot = Self.childSnapshot(from: parentSnapshot)
        let encodedSnapshot = try ExecutionSnapshotCodec.encode(childSnapshot)
        let child: AgentRunRecord
        if let childRunID = try store.delegatedChildRunID(parentToolCallID: parentToolCallID) {
            guard let existing = try store.run(id: childRunID),
                  existing.kind == .child,
                  existing.parentRunID == parent.id
            else { throw DelegationRuntimeError.unavailableChildOutcome(childRunID) }
            guard let frozen = existing.executionSnapshot,
                  try ExecutionSnapshotCodec.decode(frozen) == childSnapshot
            else { throw DelegationRuntimeError.unavailableParentPolicy }
            child = existing
        } else {
            let childID = "run-\(UUID().uuidString)"
            let now = Date()
            let newChild = AgentRunRecord(
                id: childID,
                conversationID: parent.conversationID,
                kind: .child,
                parentRunID: parent.id,
                state: .preparing,
                endReason: nil,
                recoveryAction: nil,
                suspendReason: nil,
                triggerMessageID: nil,
                responseMessageID: nil,
                retryOfRunID: nil,
                requestConfigSeed: parent.requestConfigSeed,
                executionSnapshot: encodedSnapshot,
                createdAt: now,
                updatedAt: now,
                activeSlot: nil,
                submissionID: nil,
                submissionDigest: nil
            )
            try store.createDelegatedChildRun(
                parentToolCallID: parentToolCallID,
                childRun: newChild,
                at: now
            )
            child = try requiredChild(id: childID)
        }
        return child
    }

    private static func childSnapshot(from parent: RunExecutionSnapshot) -> RunExecutionSnapshot {
        var capabilities = parent.modelCapabilities
        capabilities.remove(.tools)
        return RunExecutionSnapshot(
            providerID: parent.providerID,
            providerAdapterRevision: parent.providerAdapterRevision,
            prompt: PromptExecutionSnapshot(
                runtimeSafetyBaseline: parent.prompt.runtimeSafetyBaseline,
                zenCore: parent.prompt.zenCore,
                providerAdapterInstructions: parent.prompt.providerAdapterInstructions
            ),
            modelCapabilities: capabilities,
            exposedTools: [],
            mcpServerDependencies: [],
            maxProviderSteps: parent.maxProviderSteps,
            delegation: nil
        )
    }

    private func enabledParentSnapshot(_ parent: AgentRunRecord) throws -> RunExecutionSnapshot {
        guard parent.kind == .parent,
              let encoded = parent.executionSnapshot,
              let snapshot = try? ExecutionSnapshotCodec.decode(encoded),
              snapshot.providerID == provider.id,
              snapshot.providerAdapterRevision == provider.adapterRevision,
              snapshot.maxProviderSteps > 0,
              snapshot.modelCapabilities.contains(.text),
              snapshot.modelCapabilities.contains(.streaming),
              let delegation = snapshot.delegation,
              delegation.enabled,
              delegation.maxDepth == 1,
              delegation.maxConcurrentChildren == 1,
              delegation.modelPolicy == .followParent,
              delegation.environmentInheritance == .none,
              snapshot.permitsTool(SubagentDelegationTool.toolDescriptor)
        else { throw DelegationRuntimeError.unavailableParentPolicy }
        return snapshot
    }

    private func requiredParent(id: String) throws -> AgentRunRecord {
        guard let parent = try store.run(id: id),
              parent.kind == .parent,
              parent.parentRunID == nil
        else { throw DelegationRuntimeError.invalidParent(id) }
        return parent
    }

    private func requiredChild(id: String) throws -> AgentRunRecord {
        guard let child = try store.run(id: id), child.kind == .child else {
            throw DelegationRuntimeError.unavailableChildOutcome(id)
        }
        return child
    }

    private func requiredDelegationCall(id: String, parentRunID: String) throws -> ToolCallRecord {
        guard let call = try store.toolCall(id: id),
              call.agentRunID == parentRunID,
              call.action == SubagentDelegationTool.toolID,
              let encoded = call.executionIntent,
              let intent = try? ToolIntentCodec.decodeForDisplay(encoded),
              intent.resourceScope == .target(parentRunID)
        else { throw DelegationRuntimeError.invalidToolCall(id) }
        return call
    }

    private func cancelChild(_ childRunID: String, parentRunID: String) async {
        guard let child = try? store.run(id: childRunID), child.state.isActive else { return }
        do {
            try await agentRuntime.stop(runID: childRunID)
        } catch AgentRuntimeError.runIsNotActive {
            _ = try? store.cancelTasklessDelegatedChildren(parentRunID: parentRunID)
        } catch {
            return
        }
    }
}

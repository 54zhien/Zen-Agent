import Foundation

enum DelegationRuntimeError: Error, Sendable {
    case invalidParent(String)
    case invalidToolCall(String)
    case unavailableParentPolicy
    case unavailableParentToolRegistry(String)
    case unavailableChildOutcome(String)
    case unsupportedChildState(String, RunState)
}

struct DelegatedChildAuthenticationRequired: Error, Sendable {
    let providerID: ProviderID
    let providerInstanceID: ProviderInstanceID
    let modelID: ModelID
}

private struct PreparedDelegatedChildContext: Sendable {
    let snapshot: RunExecutionSnapshot
    let requestConfigSeed: RequestConfigSeed
    let toolContext: ToolRuntimeRegistryContext
    let memories: [MemoryContext]
    let skills: [SkillContext]
}

/// Owns the Child Run lifecycle for one Parent ToolCall. ConversationRuntime still
/// owns event projection; AgentRuntime owns run execution and transitions; the store
/// owns the stable Parent ToolCall-to-Child identity.
actor DelegationRuntime {
    private let store: PersistenceStore
    private let provider: any ModelProvider
    private let credentials: any CredentialStoring
    private let agentRuntime: AgentRuntime
    private let project: AgentEventProjection

    init(
        store: PersistenceStore,
        provider: any ModelProvider,
        credentials: any CredentialStoring,
        agentRuntime: AgentRuntime,
        project: @escaping AgentEventProjection
    ) {
        self.store = store
        self.provider = provider
        self.credentials = credentials
        self.agentRuntime = agentRuntime
        self.project = project
    }

    func execute(
        parentRunID: String,
        parentToolCallID: String,
        task: String,
        environmentKeys: [String]
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
        if let unavailable = try unavailableExplicitTargetResult(in: parentSnapshot) {
            return unavailable
        }
        let childContext = try await prepareChildContext(
            parent: parent,
            parentSnapshot: parentSnapshot,
            task: task,
            environmentKeys: environmentKeys
        )
        let child = try prepareChild(
            parent: parent,
            childContext: childContext,
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
        return try await runChildWithParentStopSettlement(
            child: child,
            parent: parent,
            childContext: childContext,
            task: task
        )
    }

    /// Resumes the Parent's original delegated call by reconciling its stable Child
    /// identity. A Child with a persisted Step is recovered from its own checkpoint;
    /// a Child without one has not crossed the provider request boundary.
    func resumeDispatchedChild(
        parentRunID: String,
        parentToolCallID: String,
        task: String,
        environmentKeys: [String]
    ) async throws -> ToolExecutionResult {
        let parent = try requiredParent(id: parentRunID)
        guard parent.state == .executingTools else {
            throw DelegationRuntimeError.invalidParent(parentRunID)
        }
        let call = try requiredDelegationCall(id: parentToolCallID, parentRunID: parentRunID)
        guard call.state == .dispatched || call.state == .indeterminate else {
            throw DelegationRuntimeError.invalidToolCall(parentToolCallID)
        }
        let parentSnapshot = try enabledParentSnapshot(parent)
        if let unavailable = try unavailableExplicitTargetResult(in: parentSnapshot) {
            return unavailable
        }
        let childContext = try await prepareChildContext(
            parent: parent,
            parentSnapshot: parentSnapshot,
            task: task,
            environmentKeys: environmentKeys
        )
        let child = try prepareChild(
            parent: parent,
            childContext: childContext,
            parentToolCallID: parentToolCallID
        )
        if child.state.isTerminal {
            guard let outcome = try store.delegatedChildOutcome(runID: child.id) else {
                throw DelegationRuntimeError.unavailableChildOutcome(child.id)
            }
            return outcome
        }

        let childSnapshot: RunExecutionSnapshot
        guard let encoded = child.executionSnapshot else {
            throw DelegationRuntimeError.unavailableParentPolicy
        }
        childSnapshot = try ExecutionSnapshotCodec.decode(encoded)
        guard childSnapshot == childContext.snapshot else {
            throw DelegationRuntimeError.unavailableParentPolicy
        }
        await agentRuntime.bindToolRegistry(childContext.toolContext, forRunID: child.id)

        if try store.steps(inRun: child.id).isEmpty {
            guard child.state == .preparing || child.state == .requestingModel else {
                await agentRuntime.releaseToolRegistry(forRunID: child.id)
                throw DelegationRuntimeError.unsupportedChildState(child.id, child.state)
            }
            return try await runChildWithParentStopSettlement(
                child: child,
                parent: parent,
                childContext: childContext,
                task: task
            )
        }

        let latestChildStep = try store.steps(inRun: child.id).last
        let childHasCredentialFailureEvidence = latestChildStep?.credentialFailureSource != nil
            && latestChildStep?.credentialFailureAt != nil
            && latestChildStep?.providerStartedAt != nil
            && latestChildStep?.protocolResponse == nil
        let childWasWaitingForAuthentication = childHasCredentialFailureEvidence
            && ((child.state == .suspended && child.suspendReason == .authRequired)
                || (child.state == .recovering && child.recoveryAction == .reprepare))
        try await agentRuntime.recoverRun(runID: child.id, project: project)
        guard let recoveredChild = try store.run(id: child.id) else {
            await agentRuntime.releaseToolRegistry(forRunID: child.id)
            throw DelegationRuntimeError.unavailableChildOutcome(child.id)
        }
        if recoveredChild.state.isTerminal {
            await agentRuntime.releaseToolRegistry(forRunID: child.id)
            guard let outcome = try store.delegatedChildOutcome(runID: child.id) else {
                throw DelegationRuntimeError.unavailableChildOutcome(child.id)
            }
            return outcome
        }
        if recoveredChild.state == .suspended,
           recoveredChild.suspendReason == .authRequired {
            await agentRuntime.releaseToolRegistry(forRunID: child.id)
            throw DelegatedChildAuthenticationRequired(
                providerID: provider.id,
                providerInstanceID: recoveredChild.requestConfigSeed.providerInstanceID,
                modelID: recoveredChild.requestConfigSeed.modelID
            )
        }
        if childWasWaitingForAuthentication, recoveredChild.state == .requestingModel {
            let initialRequest = try childRequest(
                child: recoveredChild,
                snapshot: childSnapshot,
                childContext: childContext,
                task: task
            )
            let retryRequest = try RunRequestRebuilder(
                store: store,
                provider: provider,
                toolRegistry: childContext.toolContext.registry,
                credentials: credentials
            ).authenticationRetryRequest(
                for: recoveredChild,
                snapshot: childSnapshot,
                initialRequest: initialRequest
            )
            return try await runChildWithParentStopSettlement(
                child: recoveredChild,
                parent: parent,
                childContext: childContext,
                task: task,
                requestOverride: retryRequest
            )
        }
        guard recoveredChild.state == .waitingForApproval || recoveredChild.state == .executingTools
                || recoveredChild.state == .continuing || recoveredChild.state == .requestingModel else {
            await agentRuntime.releaseToolRegistry(forRunID: child.id)
            throw DelegationRuntimeError.unsupportedChildState(child.id, recoveredChild.state)
        }

        let request = try childRequest(
            child: recoveredChild,
            snapshot: childSnapshot,
            childContext: childContext,
            task: task
        )
        let batch: RecoveredToolBatch
        do {
            batch = try RunRequestRebuilder(
                store: store,
                provider: provider,
                toolRegistry: childContext.toolContext.registry,
                credentials: credentials
            ).latestToolBatch(
                for: recoveredChild,
                snapshot: childSnapshot,
                initialRequest: request
            )
        } catch RunRequestRebuildError.incompleteCommittedInput {
            if let currentChild = try store.run(id: child.id), currentChild.state.isActive {
                try store.settleTasklessRun(
                    id: child.id,
                    expectedState: currentChild.state,
                    terminalState: .failed,
                    endReason: .unrecoverable
                )
                try await project(.runStateChanged(runID: child.id, state: .failed))
                try await project(.runEnded(runID: child.id, state: .failed, endReason: .unrecoverable))
            }
            await agentRuntime.releaseToolRegistry(forRunID: child.id)
            guard let outcome = try store.delegatedChildOutcome(runID: child.id) else {
                throw DelegationRuntimeError.unavailableChildOutcome(child.id)
            }
            return outcome
        }
        let stream = await agentRuntime.advanceRecoveredToolBatch(
            runID: child.id,
            batch: batch,
            snapshot: childSnapshot,
            project: project
        )
        return try await waitForChild(stream, child: recoveredChild, parent: parent)
    }

    private func runChildWithParentStopSettlement(
        child: AgentRunRecord,
        parent: AgentRunRecord,
        childContext: PreparedDelegatedChildContext,
        task: String,
        requestOverride: ProviderChatRequest? = nil
    ) async throws -> ToolExecutionResult {
        do {
            return try await runChild(
                child: child,
                parent: parent,
                childContext: childContext,
                task: task,
                requestOverride: requestOverride
            )
        } catch {
            let parentIsStopping = (try? store.run(id: parent.id))?.state == .stopping
            if Task.isCancelled || parentIsStopping {
                await cancelChild(child.id, parentRunID: parent.id)
            }
            throw error
        }
    }

    private func runChild(
        child: AgentRunRecord,
        parent: AgentRunRecord,
        childContext: PreparedDelegatedChildContext,
        task: String,
        requestOverride: ProviderChatRequest? = nil
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
              childSnapshot.mcpServerDependencies.isEmpty,
              childSnapshot == childContext.snapshot,
              childSnapshot.exposedTools == Self.toolExposures(from: childContext.toolContext.registry)
        else { throw DelegationRuntimeError.unavailableParentPolicy }

        let request: ProviderChatRequest
        if let requestOverride {
            request = requestOverride
        } else {
            request = try childRequest(
                child: child,
                snapshot: childSnapshot,
                childContext: childContext,
                task: task
            )
        }

        await agentRuntime.bindToolRegistry(childContext.toolContext, forRunID: child.id)
        let stream = await agentRuntime.advance(
            runID: child.id,
            request: request,
            snapshot: childSnapshot,
            project: project
        )
        return try await waitForChild(stream, child: child, parent: parent)
    }

    private func childRequest(
        child: AgentRunRecord,
        snapshot: RunExecutionSnapshot,
        childContext: PreparedDelegatedChildContext,
        task: String
    ) throws -> ProviderChatRequest {
        let sections = try PromptTemplateCatalog.resolve(
            runtimeSafetyRevision: snapshot.prompt.runtimeSafetyBaseline,
            zenCoreRevision: snapshot.prompt.zenCore
        )
        let soulInstructions: String?
        if let soulVersionID = snapshot.prompt.soulVersionID {
            guard let version = try store.soulVersion(id: soulVersionID) else {
                throw DelegationRuntimeError.unavailableParentPolicy
            }
            soulInstructions = version.instructions
        } else {
            soulInstructions = nil
        }
        return PromptComposer().compose(PromptCompositionInput(
            modelID: child.requestConfigSeed.modelID,
            providerAdapterInstructions: snapshot.prompt.providerAdapterInstructions,
            history: [],
            currentUserMessage: task,
            soulInstructions: soulInstructions,
            relevantMemories: childContext.memories.map(\.content),
            activatedSkills: childContext.skills,
            tools: snapshot.exposedTools.map {
                ProviderToolDefinition(
                    name: $0.toolID,
                    description: $0.description,
                    parameters: $0.inputSchema
                )
            },
            systemSections: sections
        ))
    }

    private func waitForChild(
        _ stream: AsyncThrowingStream<AgentEvent, Error>,
        child: AgentRunRecord,
        parent: AgentRunRecord
    ) async throws -> ToolExecutionResult {
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

        do {
            let result = try await withTaskCancellationHandler {
                try await childExecution.value
            } onCancel: {
                Task { await self.cancelChild(child.id, parentRunID: parent.id) }
            }
            await agentRuntime.releaseToolRegistry(forRunID: child.id)
            return result
        } catch {
            if !Task.isCancelled,
               let currentChild = try? store.run(id: child.id),
               currentChild.state == .suspended,
               currentChild.suspendReason == .authRequired {
                await agentRuntime.releaseToolRegistry(forRunID: child.id)
                throw DelegatedChildAuthenticationRequired(
                    providerID: provider.id,
                    providerInstanceID: currentChild.requestConfigSeed.providerInstanceID,
                    modelID: currentChild.requestConfigSeed.modelID
                )
            }
            if Task.isCancelled {
                await cancelChild(child.id, parentRunID: parent.id)
                _ = try? await childExecution.value
            }
            await agentRuntime.releaseToolRegistry(forRunID: child.id)
            throw error
        }
    }

    private func prepareChild(
        parent: AgentRunRecord,
        childContext: PreparedDelegatedChildContext,
        parentToolCallID: String
    ) throws -> AgentRunRecord {
        let childSnapshot = childContext.snapshot
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
                requestConfigSeed: childContext.requestConfigSeed,
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

    private static func childSnapshot(
        from parent: RunExecutionSnapshot,
        modelBinding: DelegationModelBindingSnapshot?,
        modelCapabilities: Set<ModelCapability>,
        tools: [ToolExposureSnapshot],
        memories: [MemoryContext],
        skillReferences: [SkillActivationReference]
    ) -> RunExecutionSnapshot {
        var capabilities = modelCapabilities
        if tools.isEmpty { capabilities.remove(.tools) }
        return RunExecutionSnapshot(
            providerID: modelBinding?.providerID ?? parent.providerID,
            providerAdapterRevision: modelBinding?.providerAdapterRevision ?? parent.providerAdapterRevision,
            prompt: PromptExecutionSnapshot(
                runtimeSafetyBaseline: parent.prompt.runtimeSafetyBaseline,
                zenCore: parent.prompt.zenCore,
                providerAdapterInstructions: parent.prompt.providerAdapterInstructions,
                soulVersionID: parent.prompt.soulVersionID,
                memoryReferences: memories.map(\.reference),
                skillReferences: skillReferences
            ),
            modelCapabilities: capabilities,
            exposedTools: tools,
            mcpServerDependencies: [],
            maxProviderSteps: parent.maxProviderSteps,
            delegation: nil
        )
    }

    private func prepareChildContext(
        parent: AgentRunRecord,
        parentSnapshot: RunExecutionSnapshot,
        task: String,
        environmentKeys: [String]
    ) async throws -> PreparedDelegatedChildContext {
        guard let parentContext = await agentRuntime.toolRegistryContext(forRunID: parent.id) else {
            throw DelegationRuntimeError.unavailableParentToolRegistry(parent.id)
        }
        let modelBinding = try childModelBinding(in: parentSnapshot)
        let modelCapabilities = modelBinding?.modelCapabilities ?? parentSnapshot.modelCapabilities
        let requestConfigSeed = modelBinding?.requestConfigSeed ?? parent.requestConfigSeed
        let childRegistry = try parentContext.registry.filteringExecutables { executable in
            let descriptor = executable.descriptor
            guard modelCapabilities.contains(.tools),
                  descriptor.id != SubagentDelegationTool.toolID,
                  !(executable is MCPToolExecutable),
                  parentSnapshot.permitsTool(descriptor),
                  parentSnapshot.exposedTools.contains(where: { Self.exposure($0, matches: descriptor) })
            else { return false }
            return true
        }
        let childToolContext = ToolRuntimeRegistryContext(registry: childRegistry)
        let memoryRuntime = MemoryRuntime(store: store, credentials: credentials)
        let memoryCandidates = try memoryRuntime.resolveFrozen(parentSnapshot.prompt.memoryReferences)
        let memories = MemoryRetriever.select(query: task, contexts: memoryCandidates)
        let parentSkillItems = try store.resolveSkillItems(parentSnapshot.prompt.skillReferences)
        let parentEnvironmentReferences = Array(Set(
            parentSnapshot.prompt.skillReferences.flatMap(\.environmentReferences)
        )).sorted {
            if $0.variableID != $1.variableID { return $0.variableID < $1.variableID }
            return $0.revisionID < $1.revisionID
        }
        let availableEnvironmentKeys = Set(
            try store.resolveEnvironmentReferences(parentEnvironmentReferences).map(\.key)
        )
        let requestedEnvironmentKeys = Set(environmentKeys)
        guard requestedEnvironmentKeys.isSubset(of: availableEnvironmentKeys) else {
            throw DelegationRuntimeError.unavailableParentPolicy
        }
        let childToolIDs = Set(childRegistry.descriptors.map(\.id))
        let skillCandidates = parentSkillItems.filter { item in
            item.definition.requiredTools.allSatisfy { childToolIDs.contains($0) }
                && item.definition.requiredMCPServers.isEmpty
                && Set(item.definition.environmentKeys).isSubset(of: requestedEnvironmentKeys)
        }
        let selectedSkillItems = SkillRouter.select(query: task, candidates: skillCandidates)
        let skillReferences = try selectedSkillItems.map { selected -> SkillActivationReference in
            guard let reference = parentSnapshot.prompt.skillReferences.first(where: {
                $0.skillID == selected.id && $0.revisionID == selected.revisionID
            }) else { throw SkillError.erasedDependency }
            return reference
        }
        let skills = try SkillRuntime(
            store: store,
            credentials: credentials,
            registry: childRegistry
        ).resolveFrozen(skillReferences)
        let context = PreparedDelegatedChildContext(
            snapshot: Self.childSnapshot(
                from: parentSnapshot,
                modelBinding: modelBinding,
                modelCapabilities: modelCapabilities,
                tools: Self.toolExposures(from: childRegistry),
                memories: memories,
                skillReferences: skillReferences
            ),
            requestConfigSeed: requestConfigSeed,
            toolContext: childToolContext,
            memories: memories,
            skills: skills
        )
        return context
    }

    private static func toolExposures(from registry: ToolRegistry) -> [ToolExposureSnapshot] {
        registry.descriptors.map {
            ToolExposureSnapshot(
                toolID: $0.id,
                descriptorRevision: $0.revision,
                displayName: $0.displayName,
                description: $0.description,
                inputSchema: $0.inputSchema
            )
        }
    }

    private static func exposure(_ exposure: ToolExposureSnapshot, matches descriptor: ToolDescriptor) -> Bool {
        exposure.toolID == descriptor.id
            && exposure.descriptorRevision == descriptor.revision
            && exposure.displayName == descriptor.displayName
            && exposure.description == descriptor.description
            && exposure.inputSchema == descriptor.inputSchema
    }

    private func unavailableExplicitTargetResult(
        in parentSnapshot: RunExecutionSnapshot
    ) throws -> ToolExecutionResult? {
        guard let delegation = parentSnapshot.delegation,
              delegation.modelPolicy == .explicit else { return nil }
        guard let target = delegation.explicitModelTarget else {
            return ToolExecutionResult(
                content: "dependencyUnavailable: The configured Child model target is unavailable. No Parent model fallback was used.",
                kind: .error,
                failure: .dependencyUnavailable
            )
        }

        guard let instance = try store.providerInstance(id: target.providerInstanceID),
              instance.providerID == provider.id,
              let descriptor = provider.descriptor(for: target.modelID, in: instance),
              descriptor.providerInstanceID == instance.id,
              descriptor.capabilities.contains(.text),
              descriptor.capabilities.contains(.streaming)
        else {
            return ToolExecutionResult(
                content: "dependencyUnavailable: Configured Child target instance \(target.providerInstanceID.rawValue), model \(target.modelID.rawValue) is not supported by this Runtime. No Parent model fallback was used.",
                kind: .error,
                failure: .dependencyUnavailable
            )
        }

        let binding = delegation.explicitModelBinding
        let bindingMatchesTarget = binding.map {
            $0.providerID == provider.id
                && $0.providerAdapterRevision == provider.adapterRevision
                && $0.requestConfigSeed.providerInstanceID == target.providerInstanceID
                && $0.requestConfigSeed.modelID == target.modelID
                && $0.modelCapabilities.contains(.text)
                && $0.modelCapabilities.contains(.streaming)
        } ?? false
        guard let binding else {
            return ToolExecutionResult(
                content: "authenticationRequired: Provider \(instance.providerID.rawValue), model \(target.modelID.rawValue), instance \(target.providerInstanceID.rawValue) has no frozen credential binding. Restore credentials for this target and start a new delegation. No Parent model fallback was used.",
                kind: .error,
                failure: .authenticationRequired
            )
        }
        guard bindingMatchesTarget else {
            return ToolExecutionResult(
                content: "dependencyUnavailable: Configured Child target Provider \(binding.providerID.rawValue), model \(target.modelID.rawValue) no longer matches its frozen Runtime binding. No Parent model fallback was used.",
                kind: .error,
                failure: .dependencyUnavailable
            )
        }
        return nil
    }

    private func childModelBinding(
        in parentSnapshot: RunExecutionSnapshot
    ) throws -> DelegationModelBindingSnapshot? {
        guard let delegation = parentSnapshot.delegation else {
            throw DelegationRuntimeError.unavailableParentPolicy
        }
        switch delegation.modelPolicy {
        case .followParent:
            guard delegation.explicitModelTarget == nil,
                  delegation.explicitModelBinding == nil else {
                throw DelegationRuntimeError.unavailableParentPolicy
            }
            return nil
        case .explicit:
            guard let binding = delegation.explicitModelBinding else {
                throw DelegationRuntimeError.unavailableParentPolicy
            }
            return binding
        }
    }

    private func enabledParentSnapshot(_ parent: AgentRunRecord) throws -> RunExecutionSnapshot {
        let policyMatchesTarget: (DelegationExecutionSnapshot) -> Bool = { delegation in
            switch delegation.modelPolicy {
            case .followParent:
                return delegation.explicitModelTarget == nil && delegation.explicitModelBinding == nil
            case .explicit:
                return delegation.explicitModelTarget != nil
            }
        }
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
              delegation.supportsFrozenConcurrencyLimit,
              policyMatchesTarget(delegation),
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
            _ = try? store.cancelTasklessDelegatedChild(
                parentRunID: parentRunID,
                childRunID: childRunID
            )
        } catch {
            return
        }
    }
}

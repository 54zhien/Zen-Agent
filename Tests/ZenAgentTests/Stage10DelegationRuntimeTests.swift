import Foundation
import Testing

@testable import ZenAgent

@Suite("Stage 10 delegation runtime")
struct Stage10DelegationRuntimeTests {

    @Test("an enabled Parent delegates once and resumes with the persisted Child result")
    func parentDelegatesAndContinuesFromChildResult() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let childTask = "Summarize the requested change."
        let ledger = Stage2ProviderLedger()
        let provider = Stage2ScriptedProvider(
            ledger: ledger,
            scripts: [
                .events([
                    .toolCall(ProviderToolCall(
                        id: "delegation-provider-call",
                        index: 0,
                        name: "subagent",
                        argumentsJSON: #"{"task":"Summarize the requested change."}"#
                    )),
                    .finish(.toolCalls),
                ]),
                .events([.textDelta("child answer"), .finish(.stop)]),
                .events([.textDelta("parent answer"), .finish(.stop)]),
            ]
        )
        let events = Stage10DelegationEventLedger()
        let runtime = ConversationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials,
            onEvent: { await events.append($0) }
        )
        try fixture.store.setDelegationEnabled(true)

        var command = I05RuntimeTestFixtures.command(modelID: Stage2GateFixture.modelID)
        command.text = "Review this change."
        command.conversationID = I05RuntimeTestFixtures.conversationID
        let parentRunID = try await runtime.start(command)
        let parentToolCallID = await events.waitForApproval()
        try await runtime.approve(toolCallID: parentToolCallID)
        try await runtime.waitForCompletion(runID: parentRunID)

        let parent = try #require(try fixture.store.run(id: parentRunID))
        let parentSnapshot = try ExecutionSnapshotCodec.decode(
            try #require(parent.executionSnapshot)
        )
        #expect(parent.state == .completed)
        #expect(parentSnapshot.delegation?.enabled == true)
        #expect(parentSnapshot.delegation?.maxDepth == 1)
        #expect(parentSnapshot.delegation?.maxConcurrentChildren == 1)
        #expect(parentSnapshot.delegation?.modelPolicy == .followParent)
        #expect(parentSnapshot.delegation?.environmentInheritance == DelegationEnvironmentInheritance.none)
        #expect(parentSnapshot.exposedTools.contains { $0.toolID == "subagent" })

        let runs = try fixture.store.runs(inConversation: command.conversationID)
        let child = try #require(runs.first { $0.kind == .child })
        #expect(child.parentRunID == parentRunID)
        #expect(child.requestConfigSeed == parent.requestConfigSeed)
        #expect(child.state == .completed)
        let childSnapshot = try ExecutionSnapshotCodec.decode(
            try #require(child.executionSnapshot)
        )
        #expect(!childSnapshot.modelCapabilities.contains(.tools))
        #expect(childSnapshot.exposedTools.isEmpty)
        #expect(childSnapshot.prompt.memoryReferences.isEmpty)
        #expect(childSnapshot.prompt.skillReferences.isEmpty)
        #expect(childSnapshot.delegation == nil)

        #expect(child.triggerMessageID == nil)
        let childResponseID = try #require(child.responseMessageID)
        let childAnswer = try fixture.store.parts(ofMessage: childResponseID)
            .filter { $0.kind == .text }
            .compactMap { try fixture.store.text(ofPart: $0.id) }
            .joined()
        #expect(childAnswer == "child answer")

        let parentCalls = try fixture.store.toolCalls(inRun: parentRunID)
        let delegationCall = try #require(parentCalls.first)
        #expect(delegationCall.state == .succeeded)
        let result = try #require(try fixture.store.toolResult(toolCallID: delegationCall.id))
        #expect(result.payload == "child answer")

        let requests = await ledger.requestsSnapshot()
        #expect(requests.count == 3)
        guard requests.count == 3 else { return }
        #expect(requests[0].tools.contains { $0.name == "subagent" })
        #expect(requests[1].tools.isEmpty)
        #expect(requests[1].messages.compactMap { message -> String? in
            guard case .user(let text) = message else { return nil }
            return text
        } == [childTask])
        #expect(requests[2].messages.contains { message in
            guard case .toolResult(_, let content) = message else { return false }
            return content == "child answer"
        })

        let timeline = try ConversationTimelineLoader.load(
            conversationID: command.conversationID,
            from: fixture.store
        )
        #expect(timeline.turns.map(\.runID) == [parentRunID])
    }

    @Test("Child tool approval is projected to its owning Conversation and resumes the same Child call")
    func childToolApprovalResumesSameCall() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let toolID = "stage10-child-recording-tool"
        let toolLedger = I07ToolLedger()
        let tool = I07RecordingTool(id: toolID, approvalRequirement: .required, ledger: toolLedger)
        let registry = try ToolRegistry(tools: [tool])
        try fixture.store.setMemoryEnabled(true)
        let parentMemory = try fixture.store.saveMemory(content: "Parentonly memory marker.")
        let childMemory = try fixture.store.saveMemory(content: "Childalpha memory marker.")
        let environment = EnvironmentRuntime(store: fixture.store, credentials: fixture.credentials)
        let appMode = try environment.savePlain(key: "APP_MODE", value: "sandbox")
        let skillRuntime = SkillRuntime(store: fixture.store, credentials: fixture.credentials, registry: registry)
        let childSkill = try skillRuntime.saveUser(definition: SkillDefinition(
            name: "Child Alpha",
            summary: "Child task guidance.",
            instructions: "Apply ${APP_MODE} mode.",
            requiredTools: [toolID],
            environmentKeys: ["APP_MODE"],
            triggerTerms: ["childalpha"]
        ))
        let parentOnlySkill = try skillRuntime.saveUser(definition: SkillDefinition(
            name: "Parent Only",
            summary: "Only relevant to the Parent request.",
            instructions: "Parent-only workflow.",
            environmentKeys: ["APP_MODE"],
            triggerTerms: ["parentonly"]
        ))
        try await skillRuntime.setEnabled(id: childSkill.id, enabled: true)
        try await skillRuntime.setEnabled(id: parentOnlySkill.id, enabled: true)
        let events = Stage10ApprovalLedger()
        let providerLedger = Stage2ProviderLedger()
        let provider = Stage2ScriptedProvider(
            ledger: providerLedger,
            scripts: [
                .events([
                    .toolCall(ProviderToolCall(
                        id: "parent-delegation-call",
                        index: 0,
                        name: SubagentDelegationTool.toolID,
                        argumentsJSON: #"{"task":"Use childalpha to perform the task.","environmentKeys":["APP_MODE"]}"#
                    )),
                    .finish(.toolCalls),
                ]),
                .events([
                    .toolCall(ProviderToolCall(
                        id: "child-recording-call",
                        index: 0,
                        name: toolID,
                        argumentsJSON: "{}"
                    )),
                    .finish(.toolCalls),
                ]),
                .events([.textDelta("child answer"), .finish(.stop)]),
                .events([.textDelta("parent answer"), .finish(.stop)]),
            ]
        )
        let runtime = ConversationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials,
            toolRegistry: registry,
            onEvent: { await events.append($0) }
        )
        try fixture.store.setDelegationEnabled(true)

        var command = I05RuntimeTestFixtures.command(
            text: "Use parentonly and childalpha context before delegating."
        )
        command.selectedSkillIDs = [childSkill.id, parentOnlySkill.id]
        let parentRunID = try await runtime.start(command)
        let parentCallID = await events.waitForApproval(at: 0).toolCallID
        let parentIntent = try ToolIntentCodec.decodeForDisplay(
            try #require(try fixture.store.toolCall(id: parentCallID)?.executionIntent)
        )
        #expect(parentIntent.approvalDisclosure?.keyImpact.contains("APP_MODE") == true)
        try await runtime.approve(toolCallID: parentCallID, scope: .once)

        let childApproval = await events.waitForApproval(at: 1)
        let child = try #require(try fixture.store.run(id: childApproval.runID))
        let childSnapshot = try ExecutionSnapshotCodec.decode(try #require(child.executionSnapshot))
        #expect(child.kind == .child)
        #expect(child.parentRunID == parentRunID)
        #expect(childSnapshot.exposedTools.map(\.toolID) == [toolID])
        #expect(childSnapshot.prompt.memoryReferences == [childMemory.reference])
        #expect(childSnapshot.prompt.skillReferences.map(\.skillID) == [childSkill.id])
        #expect(childSnapshot.prompt.skillReferences.first?.environmentReferences == [appMode.reference])
        #expect(try ExecutionSnapshotCodec.decode(try #require(
            try fixture.store.run(id: parentRunID)?.executionSnapshot
        )).prompt.memoryReferences.contains(parentMemory.reference))
        #expect(try ExecutionSnapshotCodec.decode(try #require(
            try fixture.store.run(id: parentRunID)?.executionSnapshot
        )).prompt.skillReferences.map(\.skillID).contains(parentOnlySkill.id))

        let requests = await providerLedger.requestsSnapshot()
        guard requests.count >= 2 else {
            Issue.record("the Child Provider request was not recorded")
            return
        }
        let childUserContent = requests[1].messages.compactMap { message -> String? in
            guard case .user(let content) = message else { return nil }
            return content
        }.joined(separator: "\n")
        #expect(childUserContent.contains("Childalpha memory marker."))
        #expect(!childUserContent.contains("Parentonly memory marker."))
        #expect(childUserContent.contains("Workflow: Child Alpha"))
        #expect(!childUserContent.contains("Workflow: Parent Only"))
        #expect(childUserContent.contains("Apply sandbox mode."))

        let cards = try await runtime.pendingToolApprovals(in: child.conversationID)
        let card = try #require(cards.first { $0.toolCallID == childApproval.toolCallID })
        #expect(card.source == .subagent)
        #expect(card.authorizationOwnerDescription == "Subagent · 本次 Child Run")
        #expect(card.availableDecisions == [.approveOnce, .rejectOnce])

        try await runtime.resolveToolApproval(card.request(for: .approveOnce))
        try await runtime.waitForCompletion(runID: parentRunID)

        #expect(try fixture.store.toolCall(id: childApproval.toolCallID)?.state == .succeeded)
        #expect(try fixture.store.toolCall(id: parentCallID)?.state == .succeeded)
        #expect(await toolLedger.snapshot().map(\.idempotencyKey) == [childApproval.toolCallID])
        #expect(try fixture.store.toolResult(toolCallID: parentCallID)?.payload.contains("child answer") == true)
    }

    @Test("cold Parent recovery resumes the original Child approval and delegated call")
    func coldApprovalResumesOriginalChildCall() async throws {
        let scenario = try makeColdApprovalScenario(scripts: [
            .events([.textDelta("child continuation"), .finish(.stop)]),
            .events([.textDelta("parent continuation"), .finish(.stop)]),
        ])

        let report = try await scenario.runtime.reconcileColdStartRuns()
        #expect(report.continuedRunIDs == [scenario.parentRunID])
        let approval = await scenario.events.waitForApproval(at: 0)
        #expect(approval.runID == scenario.childRunID)
        #expect(approval.toolCallID == scenario.childToolCallID)

        let cards = try await scenario.runtime.pendingToolApprovals(in: I05RuntimeTestFixtures.conversationID)
        let card = try #require(cards.first { $0.toolCallID == scenario.childToolCallID })
        #expect(card.source == .subagent)
        #expect(card.authorizationOwnerDescription == "Subagent · 本次 Child Run")
        #expect(card.availableDecisions == [.approveOnce, .rejectOnce])
        try await scenario.runtime.resolveToolApproval(card.request(for: .approveOnce))
        try await scenario.runtime.waitForCompletion(runID: scenario.parentRunID)

        #expect(try scenario.store.run(id: scenario.childRunID)?.state == .completed)
        #expect(try scenario.store.toolCall(id: scenario.childToolCallID)?.state == .succeeded)
        #expect(try scenario.store.toolCall(id: scenario.parentToolCallID)?.state == .succeeded)
        #expect(await scenario.toolLedger.snapshot().map(\.idempotencyKey) == [scenario.childToolCallID])
        #expect(try scenario.store.toolResult(toolCallID: scenario.parentToolCallID)?.payload.contains("child continuation") == true)

        let requests = await scenario.providerLedger.requestsSnapshot()
        #expect(requests.count == 2)
        guard requests.count == 2 else { return }
        #expect(requests[0].messages.contains { message in
            guard case .toolResult(let callID, _) = message else { return false }
            return callID == "child-provider-call"
        })
        #expect(requests[1].messages.contains { message in
            guard case .toolResult(let callID, let content) = message else { return false }
            return callID == "parent-provider-call" && content.contains("child continuation")
        })
    }

    @Test("cold Child approval rejection continues the same Child and Parent calls")
    func coldApprovalRejectionContinuesOriginalCalls() async throws {
        let scenario = try makeColdApprovalScenario(scripts: [
            .events([.textDelta("child handled rejection"), .finish(.stop)]),
            .events([.textDelta("parent continuation"), .finish(.stop)]),
        ])

        _ = try await scenario.runtime.reconcileColdStartRuns()
        let approval = await scenario.events.waitForApproval(at: 0)
        let cards = try await scenario.runtime.pendingToolApprovals(in: I05RuntimeTestFixtures.conversationID)
        let card = try #require(cards.first { $0.toolCallID == scenario.childToolCallID })
        #expect(approval.toolCallID == card.toolCallID)
        try await scenario.runtime.resolveToolApproval(card.request(for: .rejectOnce))
        try await scenario.runtime.waitForCompletion(runID: scenario.parentRunID)

        #expect(try scenario.store.run(id: scenario.childRunID)?.state == .completed)
        #expect(try scenario.store.toolCall(id: scenario.childToolCallID)?.state == .rejected)
        #expect(try scenario.store.toolCall(id: scenario.parentToolCallID)?.state == .succeeded)
        #expect(await scenario.toolLedger.snapshot().isEmpty)
        #expect(try scenario.store.toolResult(toolCallID: scenario.parentToolCallID)?.payload.contains("child handled rejection") == true)
    }

    @Test("stopping a recovered Child approval cancels Child and preserves its result on the Parent call")
    func stopDuringColdChildApprovalSettlesBothRuns() async throws {
        let scenario = try makeColdApprovalScenario(scripts: [])

        _ = try await scenario.runtime.reconcileColdStartRuns()
        let approval = await scenario.events.waitForApproval(at: 0)
        #expect(approval.runID == scenario.childRunID)
        try await scenario.runtime.stop(runID: scenario.parentRunID)
        try await scenario.runtime.waitForCompletion(runID: scenario.parentRunID)

        let parent = try #require(try scenario.store.run(id: scenario.parentRunID))
        let child = try #require(try scenario.store.run(id: scenario.childRunID))
        #expect(parent.state == .cancelled)
        #expect(child.state == .cancelled)
        #expect(try scenario.store.toolCall(id: scenario.childToolCallID)?.state == .notExecuted)
        #expect(try scenario.store.toolCall(id: scenario.parentToolCallID)?.state == .failed)
        let result = try #require(try scenario.store.toolResult(toolCallID: scenario.parentToolCallID))
        #expect(result.kind == .error)
        #expect(result.failureCode == .executionFailed)
        #expect(result.payload.contains("cancelledByUser"))
        #expect(await scenario.providerLedger.requestsSnapshot().isEmpty)
    }

    private func makeColdApprovalScenario(
        scripts: [Stage2ProviderScript]
    ) throws -> Stage10ColdApprovalScenario {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let parentRunID = "stage10-cold-parent"
        let childRunID = "stage10-cold-child"
        let parentToolCallID = "stage10-cold-parent-delegation"
        let childToolCallID = "stage10-cold-child-tool-call"
        let childToolID = "stage10-cold-child-tool"
        let providerLedger = Stage2ProviderLedger()
        let provider = Stage2ScriptedProvider(ledger: providerLedger, scripts: scripts)
        let toolLedger = I07ToolLedger()
        let childTool = I07RecordingTool(
            id: childToolID,
            approvalRequirement: .required,
            ledger: toolLedger
        )
        let registry = try ToolRegistry(tools: [childTool])
        let configuration = try fixture.store.setDelegationEnabled(true)
        let parentPrompt = PromptExecutionSnapshot(
            runtimeSafetyBaseline: PromptTemplateCatalog.currentRuntimeSafetyRevision,
            zenCore: PromptTemplateCatalog.currentZenCoreRevision,
            providerAdapterInstructions: provider.adapterPromptInstructions
        )
        let parentSnapshot = RunExecutionSnapshot(
            providerID: provider.id,
            providerAdapterRevision: provider.adapterRevision,
            prompt: parentPrompt,
            modelCapabilities: [.text, .streaming, .tools],
            exposedTools: [
                Self.exposure(childTool.descriptor),
                Self.exposure(SubagentDelegationTool.toolDescriptor),
            ],
            maxProviderSteps: 4,
            delegation: DelegationExecutionSnapshot(configuration: configuration)
        )
        let childSnapshot = RunExecutionSnapshot(
            providerID: provider.id,
            providerAdapterRevision: provider.adapterRevision,
            prompt: parentPrompt,
            modelCapabilities: [.text, .streaming, .tools],
            exposedTools: [Self.exposure(childTool.descriptor)],
            maxProviderSteps: 4,
            delegation: nil
        )

        var commit = Fixtures.send(
            conversationID: I05RuntimeTestFixtures.conversationID,
            messageID: "stage10-cold-trigger",
            runID: parentRunID
        )
        commit.run.requestConfigSeed = try provider.makeRequestConfigSeed(
            instance: fixture.instance,
            modelID: I05RuntimeTestFixtures.modelID,
            credentialBinding: CredentialBindingSnapshot(
                reference: I05RuntimeTestFixtures.credentialReference,
                generation: 1
            )
        )
        try fixture.store.commitUserTurnAndCreateParentRun(commit)
        try fixture.store.completeExecutionSnapshot(
            runID: parentRunID,
            encodedSnapshot: ExecutionSnapshotCodec.encode(parentSnapshot)
        )
        for (current, next) in zip(
            [.preparing, .requestingModel, .streaming, .toolRequested],
            [.requestingModel, .streaming, .toolRequested, .executingTools]
        ) {
            try fixture.store.transitionRun(id: parentRunID, expectedState: current, to: next)
        }

        let setupAgent = AgentRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials
        )
        let setupDelegation = DelegationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials,
            agentRuntime: setupAgent,
            project: { _ in }
        )
        let parentExecutor = SubagentDelegationTool(
            parentRunID: parentRunID,
            store: fixture.store,
            delegationRuntime: setupDelegation
        )
        let parentIntent = try parentExecutor.prepare(
            callID: parentToolCallID,
            argumentsJSON: #"{"task":"Summarize the requested change."}"#,
            context: ToolPreparationContext(
                requestConfigSeed: try #require(try fixture.store.run(id: parentRunID)?.requestConfigSeed)
            )
        )
        let encodedParentIntent = String(
            decoding: try JSONEncoder().encode(parentIntent),
            as: UTF8.self
        )
        var parentCall = Fixtures.toolCall(
            id: parentToolCallID,
            runID: parentRunID,
            action: SubagentDelegationTool.toolID,
            state: .dispatched,
            intent: encodedParentIntent
        )
        parentCall.providerCallID = "parent-provider-call"
        parentCall.batchID = "batch-\(parentRunID)-0-1"
        parentCall.batchSequence = 0
        try fixture.store.createToolCall(parentCall)
        let parentProviderCall = ProviderToolCall(
            id: "parent-provider-call",
            index: 0,
            name: SubagentDelegationTool.toolID,
            argumentsJSON: #"{"task":"Summarize the requested change."}"#
        )
        let parentStep = Fixtures.step(stepID: "step-\(parentRunID)-0", runID: parentRunID)
        try fixture.store.recordStep(parentStep)
        try fixture.store.recordProtocolResponse(
            String(decoding: try JSONEncoder().encode(ToolCallProtocolTranscript(
                assistantContent: nil,
                calls: [parentProviderCall]
            )), as: UTF8.self),
            for: parentStep
        )

        var childRun = Fixtures.run(
            id: childRunID,
            conversationID: I05RuntimeTestFixtures.conversationID,
            kind: .child,
            state: .preparing,
            parentRunID: parentRunID
        )
        childRun.requestConfigSeed = try #require(try fixture.store.run(id: parentRunID)?.requestConfigSeed)
        childRun.executionSnapshot = try ExecutionSnapshotCodec.encode(childSnapshot)
        try fixture.store.createDelegatedChildRun(
            parentToolCallID: parentToolCallID,
            childRun: childRun
        )
        for (current, next) in zip(
            [.preparing, .requestingModel, .streaming, .toolRequested, .executingTools],
            [.requestingModel, .streaming, .toolRequested, .executingTools, .waitingForApproval]
        ) {
            try fixture.store.transitionRun(id: childRunID, expectedState: current, to: next)
        }

        let childIntent = try childTool.prepare(callID: childToolCallID, argumentsJSON: "{}")
        var childCall = Fixtures.toolCall(
            id: childToolCallID,
            runID: childRunID,
            action: childToolID,
            state: .waitingForApproval,
            intent: String(decoding: try JSONEncoder().encode(childIntent), as: UTF8.self)
        )
        childCall.providerCallID = "child-provider-call"
        childCall.batchID = "batch-\(childRunID)-0-1"
        childCall.batchSequence = 0
        try fixture.store.createToolCall(childCall)
        let childProviderCall = ProviderToolCall(
            id: "child-provider-call",
            index: 0,
            name: childToolID,
            argumentsJSON: "{}"
        )
        let childStep = Fixtures.step(stepID: "step-\(childRunID)-0", runID: childRunID)
        try fixture.store.recordStep(childStep)
        try fixture.store.recordProtocolResponse(
            String(decoding: try JSONEncoder().encode(ToolCallProtocolTranscript(
                assistantContent: nil,
                calls: [childProviderCall]
            )), as: UTF8.self),
            for: childStep
        )
        try fixture.store.transitionRun(
            id: parentRunID,
            expectedState: .executingTools,
            to: .recovering,
            recoveryAction: .resume
        )

        let events = Stage10ApprovalLedger()
        let runtime = ConversationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials,
            toolRegistry: registry,
            onEvent: { await events.append($0) }
        )
        return Stage10ColdApprovalScenario(
            store: fixture.store,
            runtime: runtime,
            events: events,
            providerLedger: providerLedger,
            toolLedger: toolLedger,
            parentRunID: parentRunID,
            childRunID: childRunID,
            parentToolCallID: parentToolCallID,
            childToolCallID: childToolCallID
        )
    }

    private static func exposure(_ descriptor: ToolDescriptor) -> ToolExposureSnapshot {
        ToolExposureSnapshot(
            toolID: descriptor.id,
            descriptorRevision: descriptor.revision,
            displayName: descriptor.displayName,
            description: descriptor.description,
            inputSchema: descriptor.inputSchema
        )
    }

    @Test("delegation is disabled until its runtime configuration is enabled")
    func delegationDefaultsDisabled() throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let configuration = try fixture.store.delegationConfiguration()

        #expect(!configuration.enabled)
        #expect(configuration.revision == 0)
    }

    @Test("cold-start Parent Stop settles an undispatched delegation with its actual result")
    func coldStartStopSettlesUndispatchedDelegation() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let parentRunID = "stage10-stop-parent"
        let parentToolCallID = "stage10-stop-delegation-call"
        let uncertainCallID = "stage10-stop-unknown-call"
        try fixture.store.commitUserTurnAndCreateParentRun(Fixtures.send(
            conversationID: I05RuntimeTestFixtures.conversationID,
            messageID: "stage10-stop-trigger",
            runID: parentRunID,
            runState: .stopping
        ))
        let parent = try #require(try fixture.store.run(id: parentRunID))
        let provider = Stage2ScriptedProvider(ledger: Stage2ProviderLedger(), scripts: [])
        let delegationRuntime = DelegationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials,
            agentRuntime: AgentRuntime(
                store: fixture.store,
                provider: provider,
                credentials: fixture.credentials
            ),
            project: { _ in }
        )
        let executor = SubagentDelegationTool(
            parentRunID: parentRunID,
            store: fixture.store,
            delegationRuntime: delegationRuntime
        )
        let waitingIntent = try executor.prepare(
            callID: parentToolCallID,
            argumentsJSON: #"{"task":"Start a Child."}"#,
            context: ToolPreparationContext(requestConfigSeed: parent.requestConfigSeed)
        )
        try fixture.store.createToolCall(Fixtures.toolCall(
            id: parentToolCallID,
            runID: parentRunID,
            action: SubagentDelegationTool.toolID,
            state: .waitingForApproval,
            intent: String(decoding: try JSONEncoder().encode(waitingIntent), as: UTF8.self)
        ))
        let unknownIntent = try executor.prepare(
            callID: uncertainCallID,
            argumentsJSON: #"{"task":"Continue the Child."}"#,
            context: ToolPreparationContext(requestConfigSeed: parent.requestConfigSeed)
        )
        try fixture.store.createToolCall(Fixtures.toolCall(
            id: uncertainCallID,
            runID: parentRunID,
            action: SubagentDelegationTool.toolID,
            state: .dispatched,
            intent: String(decoding: try JSONEncoder().encode(unknownIntent), as: UTF8.self)
        ))

        let runtime = ConversationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials
        )
        let report = try await runtime.reconcileColdStartRuns()

        #expect(report.settledRunIDs == [parentRunID])
        #expect(try fixture.store.run(id: parentRunID)?.state == .cancelled)
        #expect(try fixture.store.toolCall(id: parentToolCallID)?.state == .notExecuted)
        #expect(try fixture.store.toolCall(id: uncertainCallID)?.state == .indeterminate)
        #expect(try fixture.store.toolResult(toolCallID: uncertainCallID) == nil)
        let result = try #require(try fixture.store.toolResult(toolCallID: parentToolCallID))
        #expect(result.kind == .error)
        #expect(result.failureCode == .executionFailed)
        #expect(result.payload == "Delegation ended before a Child Run was created.")
    }

    @Test("Parent dependency invalidation settles an active Child before failing the Parent")
    func parentInvalidationSettlesActiveChild() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let parentRunID = "stage10-invalidation-parent"
        let childRunID = "stage10-invalidation-child"
        let parentToolCallID = "stage10-invalidation-delegation-call"
        let provider = Stage2ScriptedProvider(ledger: Stage2ProviderLedger(), scripts: [])
        let prompt = PromptExecutionSnapshot(
            runtimeSafetyBaseline: "stage10-safety",
            zenCore: "stage10-core",
            providerAdapterInstructions: provider.adapterPromptInstructions
        )
        let descriptor = SubagentDelegationTool.toolDescriptor
        var commit = Fixtures.send(
            conversationID: I05RuntimeTestFixtures.conversationID,
            messageID: "stage10-invalidation-trigger",
            runID: parentRunID,
            runState: .executingTools
        )
        commit.run.requestConfigSeed.credentialBinding = CredentialBindingSnapshot(
            reference: I05RuntimeTestFixtures.credentialReference,
            generation: 1
        )
        commit.run.executionSnapshot = try ExecutionSnapshotCodec.encode(RunExecutionSnapshot(
            providerID: provider.id,
            providerAdapterRevision: provider.adapterRevision,
            prompt: prompt,
            modelCapabilities: [.text, .streaming, .tools],
            exposedTools: [ToolExposureSnapshot(
                toolID: descriptor.id,
                descriptorRevision: descriptor.revision,
                displayName: descriptor.displayName,
                description: descriptor.description,
                inputSchema: descriptor.inputSchema
            )],
            maxProviderSteps: 4,
            delegation: DelegationExecutionSnapshot(configuration: DelegationRuntimeConfiguration(
                enabled: true,
                revision: 1
            ))
        ))
        try fixture.store.commitUserTurnAndCreateParentRun(commit)

        let parent = try #require(try fixture.store.run(id: parentRunID))
        let delegationRuntime = DelegationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials,
            agentRuntime: AgentRuntime(
                store: fixture.store,
                provider: provider,
                credentials: fixture.credentials
            ),
            project: { _ in }
        )
        let executor = SubagentDelegationTool(
            parentRunID: parentRunID,
            store: fixture.store,
            delegationRuntime: delegationRuntime
        )
        let intent = try executor.prepare(
            callID: parentToolCallID,
            argumentsJSON: #"{"task":"Finish the requested task."}"#,
            context: ToolPreparationContext(requestConfigSeed: parent.requestConfigSeed)
        )
        let encodedIntent = try String(decoding: JSONEncoder().encode(intent), as: UTF8.self)
        try fixture.store.createToolCall(Fixtures.toolCall(
            id: parentToolCallID,
            runID: parentRunID,
            action: SubagentDelegationTool.toolID,
            state: .prepared,
            intent: encodedIntent
        ))
        try fixture.store.markToolCallDispatched(id: parentToolCallID)

        let childSnapshot = RunExecutionSnapshot(
            providerID: provider.id,
            providerAdapterRevision: provider.adapterRevision,
            prompt: prompt,
            modelCapabilities: [.text, .streaming],
            exposedTools: [],
            maxProviderSteps: 4,
            delegation: nil
        )
        var child = Fixtures.run(
            id: childRunID,
            conversationID: parent.conversationID,
            kind: .child,
            state: .preparing,
            parentRunID: parentRunID
        )
        child.requestConfigSeed = parent.requestConfigSeed
        child.executionSnapshot = try ExecutionSnapshotCodec.encode(childSnapshot)
        try fixture.store.createDelegatedChildRun(
            parentToolCallID: parentToolCallID,
            childRun: child
        )
        try fixture.store.transitionRun(
            id: childRunID,
            expectedState: .preparing,
            to: .requestingModel
        )
        try fixture.store.transitionRun(
            id: parentRunID,
            expectedState: .executingTools,
            to: .recovering,
            recoveryAction: .invalidate
        )

        let toolRuntime = ToolRuntime(
            store: fixture.store,
            registry: try ToolRegistry.empty.merging([executor]),
            credentials: fixture.credentials
        )
        toolRuntime.bind(registry: try ToolRegistry.empty.merging([executor]), forRunID: parentRunID)
        try await RunRecovery(store: fixture.store, toolRuntime: toolRuntime).recover(runID: parentRunID)

        let recoveredParent = try #require(try fixture.store.run(id: parentRunID))
        let recoveredChild = try #require(try fixture.store.run(id: childRunID))
        let recoveredCall = try #require(try fixture.store.toolCall(id: parentToolCallID))
        let result = try #require(try fixture.store.toolResult(toolCallID: parentToolCallID))
        #expect(recoveredParent.state == .failed)
        #expect(recoveredParent.endReason == .dependencyUnavailable)
        #expect(recoveredChild.state == .failed)
        #expect(recoveredChild.endReason == .dependencyUnavailable)
        #expect(recoveredCall.state == .failed)
        #expect(result.kind == .error)
        #expect(result.failureCode == .executionFailed)
        let payload = try #require(
            JSONSerialization.jsonObject(with: Data(result.payload.utf8)) as? [String: Any]
        )
        #expect(payload["childRunID"] as? String == childRunID)
        #expect(payload["state"] as? String == RunState.failed.rawValue)
        #expect(payload["endReason"] as? String == EndReason.dependencyUnavailable.rawValue)
    }
}

private struct Stage10ColdApprovalScenario {
    let store: PersistenceStore
    let runtime: ConversationRuntime
    let events: Stage10ApprovalLedger
    let providerLedger: Stage2ProviderLedger
    let toolLedger: I07ToolLedger
    let parentRunID: String
    let childRunID: String
    let parentToolCallID: String
    let childToolCallID: String
}

private actor Stage10DelegationEventLedger {
    private var approvalIDs: [String] = []
    private var approvalWaiters: [CheckedContinuation<String, Never>] = []

    func append(_ event: AgentEvent) {
        guard case .approvalRequired(_, let toolCallID) = event else { return }
        approvalIDs.append(toolCallID)
        let waiters = approvalWaiters
        approvalWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: toolCallID)
        }
    }

    func waitForApproval() async -> String {
        if let toolCallID = approvalIDs.first { return toolCallID }
        return await withCheckedContinuation { continuation in
            approvalWaiters.append(continuation)
        }
    }
}

private actor Stage10ApprovalLedger {
    private var approvals: [(runID: String, toolCallID: String)] = []
    private var waiters: [(index: Int, continuation: CheckedContinuation<(runID: String, toolCallID: String), Never>)] = []

    func append(_ event: AgentEvent) {
        guard case .approvalRequired(let runID, let toolCallID) = event else { return }
        approvals.append((runID, toolCallID))
        let ready = waiters.filter { $0.index < approvals.count }
        waiters.removeAll { $0.index < approvals.count }
        for waiter in ready {
            waiter.continuation.resume(returning: approvals[waiter.index])
        }
    }

    func waitForApproval(at index: Int) async -> (runID: String, toolCallID: String) {
        if approvals.indices.contains(index) { return approvals[index] }
        return await withCheckedContinuation { continuation in
            waiters.append((index, continuation))
        }
    }
}

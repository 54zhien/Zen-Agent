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
        #expect(parentSnapshot.delegation?.environmentInheritance == .none)
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

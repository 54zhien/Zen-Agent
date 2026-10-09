import Foundation
import Testing

@testable import ZenAgent

@Suite("S6-02 intent validation continuation")
struct ToolIntentContinuationTests {
    @Test(arguments: [ToolCallState.succeeded, .prepared, .approved, .waitingForApproval])
    func diskReopenPreservesV1TerminalAndRejectsV1Pending(state: ToolCallState) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("s6-v1-\(UUID().uuidString).sqlite")
        let runID = "s6-\(UUID().uuidString)"
        let callID = "call-\(runID)"
        let ledger = SideEffectLedger()
        let tool = Stage2SideEffectTool(ledger: ledger)
        let provider = Stage2ScriptedProvider(ledger: Stage2ProviderLedger(), scripts: [.events([])])
        var originalJSON = ""
        do {
            let first = try Stage2GateFixture.makeDiskComponents(at: url)
            var commit = Fixtures.send(conversationID: Stage2GateFixture.conversationID,
                messageID: "user-\(runID)", runID: runID, runState: .preparing)
            commit.conversation = try #require(try first.store.conversation(id: Stage2GateFixture.conversationID))
            commit.run.requestConfigSeed = try provider.makeRequestConfigSeed(instance: first.instance,
                modelID: Stage2GateFixture.modelID, credentialBinding: CredentialBindingSnapshot(
                    reference: Stage2GateFixture.credentialReference, generation: 1))
            try first.store.commitUserTurnAndCreateParentRun(commit)
            let descriptor = tool.descriptor
            let snapshot = RunExecutionSnapshot(providerID: .deepSeek, providerAdapterRevision: provider.adapterRevision,
                prompt: PromptExecutionSnapshot(runtimeSafetyBaseline: PromptTemplateCatalog.currentRuntimeSafetyRevision,
                    zenCore: PromptTemplateCatalog.currentZenCoreRevision, providerAdapterInstructions: ""),
                modelCapabilities: [.text, .streaming, .tools], exposedTools: [ToolExposureSnapshot(
                    toolID: descriptor.id, descriptorRevision: descriptor.revision, displayName: descriptor.displayName,
                    description: descriptor.description, inputSchema: descriptor.inputSchema)], maxProviderSteps: 4)
            try first.store.completeExecutionSnapshot(runID: runID, encodedSnapshot: try ExecutionSnapshotCodec.encode(snapshot))
            try first.store.recordStep(Fixtures.step(stepID: "step-\(runID)", runID: runID))
            try first.store.transitionRun(id: runID, expectedState: .preparing, to: .requestingModel)
            try first.store.transitionRun(id: runID, expectedState: .requestingModel, to: .toolRequested)
            try first.store.transitionRun(id: runID, expectedState: .toolRequested, to: .executingTools)
            var intent = try tool.prepare(callID: callID, argumentsJSON: "{}")
            intent.formatVersion = 1
            intent.policyAction = nil
            intent.resourceScope = nil
            intent.destinationScope = nil
            originalJSON = String(decoding: try JSONEncoder().encode(intent), as: UTF8.self)
            try first.store.createToolCall(ToolCallRecord(id: callID, agentRunID: runID, action: descriptor.id,
                state: state == .succeeded ? .prepared : state, executionIntent: originalJSON, attempt: 1,
                providerCallID: "provider-\(callID)", batchID: "batch-\(runID)-0-1", batchSequence: 0,
                createdAt: Fixtures.epoch, updatedAt: Fixtures.epoch))
            if state == .succeeded {
                try first.store.markToolCallDispatched(id: callID)
                try first.store.finishDispatchedToolCall(id: callID, expectedAttempt: 1, state: .succeeded,
                    result: ToolResultRecord(toolCallID: callID, payload: "historical result", createdAt: Fixtures.epoch))
                try first.store.transitionRun(id: runID, expectedState: .executingTools, to: .continuing)
            }
        }
        let reopened = try Stage2GateFixture.reopen(url)
        let credentials = CredentialStore(secrets: InMemorySecretBackend(), metadataRepository: InMemoryCredentialMetadataRepository())
        try credentials.provision(SecretValue("stage2-gate-secret"), as: Stage2GateFixture.credentialReference)
        let providerLedger = Stage2ProviderLedger()
        let runtime = ConversationRuntime(store: reopened, provider: Stage2ScriptedProvider(ledger: providerLedger,
            scripts: [.events([.textDelta("continued"), .finish(.stop)])]), credentials: credentials,
            toolRegistry: try ToolRegistry(tools: [tool]))
        let report = try await runtime.reconcileColdStartRuns()
        #expect(report.continuedRunIDs == [runID])
        // Bound the RED waiting path: an old approval must not stay in an invisible wait.
        for _ in 0..<100 {
            if try reopened.run(id: runID)?.state.isTerminal == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try reopened.run(id: runID)?.state == .completed)
        if try reopened.run(id: runID)?.state.isActive == true { try await runtime.stop(runID: runID) }
        try await runtime.waitForCompletion(runID: runID)
        #expect(await ledger.snapshot().isEmpty)
        #expect(try reopened.toolCalls(inRun: runID).map(\.id) == [callID])
        #expect(try reopened.toolCall(id: callID)?.executionIntent == originalJSON)
        #expect(try reopened.toolCall(id: callID)?.state == (state == .succeeded ? .succeeded : .rejected))
        let expected = state == .succeeded ? "historical result" : ToolIntentFailure.legacyIntentRequiresReapproval.resultContent
        #expect(try reopened.toolResult(toolCallID: callID)?.payload == expected)
        let requests = await providerLedger.requestsSnapshot()
        #expect(requests.count == 1)
        #expect(requests.first?.messages.contains(.toolResult(toolCallID: "provider-\(callID)", content: expected)) == true)
    }

    @Test func invalidArgumentsPersistStableOriginalResult() async throws {
        let store = try S6IntentFixture.store()
        let runtime = ToolRuntime(store: store, registry: try ToolRegistry(tools: [CalculatorTool()]))
        do {
            _ = try await runtime.complete(agentRunID: "s6-run", providerCallID: "invalid", toolID: "calculator",
                argumentsJSON: "{\"secret\":\"never disclose\"}", batchID: "batch", batchSequence: 0)
        } catch { Issue.record("validation rejection must be a durable result, got \(error)") }
        let calls = try store.toolCalls(inRun: "s6-run")
        #expect(calls.count == 1)
        if let call = calls.first {
            #expect(call.state == .rejected)
            #expect(call.providerCallID == "invalid")
            #expect(try store.toolResult(toolCallID: call.id)?.payload == ToolIntentFailure.invalidArguments.resultContent)
        }
    }

    @Test func invalidThenValidCallsReachProviderContinuation() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let ledger = I07ProviderLedger()
        let provider = I07ScriptedProvider(ledger: ledger, instanceID: fixture.instance.id, scripts: [
            [.toolCall(.init(id: "invalid", index: 0, name: "calculator", argumentsJSON: "{\"wrong\":true}")),
             .toolCall(.init(id: "valid", index: 1, name: "calculator", argumentsJSON: "{\"expression\":\"2+3\"}")),
             .finish(.toolCalls)], [.textDelta("continued"), .finish(.stop)]
        ], toolLedger: I07ToolLedger(), store: fixture.store, conversationID: I05RuntimeTestFixtures.conversationID)
        let runtime = ConversationRuntime(store: fixture.store, provider: provider, credentials: fixture.credentials,
            toolRegistry: try ToolRegistry(tools: [CalculatorTool()]))
        let runID = try await runtime.start(I05RuntimeTestFixtures.command())
        try await runtime.waitForCompletion(runID: runID)
        #expect(try fixture.store.run(id: runID)?.state == .completed)
        let calls = try fixture.store.toolCalls(inRun: runID).sorted { ($0.batchSequence ?? 0) < ($1.batchSequence ?? 0) }
        #expect(calls.count == 2)
        #expect(calls.map(\.state) == [.rejected, .succeeded])
        let requests = await ledger.requestsSnapshot()
        #expect(requests.count == 2)
        if requests.count == 2 {
            let results = requests[1].messages.compactMap { message -> String? in
                guard case .toolResult(_, let content) = message else { return nil }
                return content
            }
            #expect(results == [ToolIntentFailure.invalidArguments.resultContent, "5.0"])
        }
    }
}

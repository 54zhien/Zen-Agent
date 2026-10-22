import Foundation
import Testing

@testable import ZenAgent

@Suite("S6-02 intent validation continuation")
struct ToolIntentContinuationTests {
    @Test(arguments: [ToolCallState.succeeded, .prepared, .approved, .waitingForApproval])
    func diskReopenPreservesV1TerminalAndRejectsV1Pending(state: ToolCallState) async throws {
        let url = try Fixtures.scratchPath(name: "legacy-intent.sqlite")
        defer { Fixtures.cleanUp(url) }
        try await checkDiskReopen(at: url, state: state, format: "legacy")
    }

    @Test(arguments: [ToolCallState.prepared, .approved, .waitingForApproval], ["corrupt", "future"])
    func diskReopenRejectsUnreadablePendingIntentBeforeTranscriptRebuild(state: ToolCallState, format: String) async throws {
        let url = try Fixtures.scratchPath(name: "unreadable-intent.sqlite")
        defer { Fixtures.cleanUp(url) }
        try await checkDiskReopen(at: url, state: state, format: format)
    }

    private func checkDiskReopen(at url: URL, state: ToolCallState, format: String) async throws {
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
            let initialRunState: RunState = state == .waitingForApproval || state == .approved
                ? .waitingForApproval : .executingTools
            try first.store.transitionRun(id: runID, expectedState: .toolRequested, to: initialRunState)
            var intent = try tool.prepare(callID: callID, argumentsJSON: "{}")
            if format == "legacy" {
                intent.formatVersion = 1
                intent.policyAction = nil
                intent.resourceScope = nil
                intent.destinationScope = nil
            } else {
                intent.formatVersion = 999
            }
            originalJSON = format == "corrupt" ? "{"
                : String(decoding: try JSONEncoder().encode(intent), as: UTF8.self)
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
        if format == "legacy" { #expect(report.continuedRunIDs == [runID]) }
        else { #expect(report.settledRunIDs == [runID]) }
        // Bound the RED waiting path: an old approval must not stay in an invisible wait.
        for _ in 0..<100 {
            if try reopened.run(id: runID)?.state.isTerminal == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try reopened.run(id: runID)?.state == (format == "legacy" ? .completed : .failed))
        if try reopened.run(id: runID)?.state.isActive == true { try await runtime.stop(runID: runID) }
        try await runtime.waitForCompletion(runID: runID)
        #expect(await ledger.snapshot().isEmpty)
        #expect(try reopened.toolCalls(inRun: runID).map(\.id) == [callID])
        #expect(try reopened.toolCall(id: callID)?.executionIntent == originalJSON)
        #expect(try reopened.toolCall(id: callID)?.attempt == 1)
        #expect(try reopened.toolCall(id: callID)?.state == (state == .succeeded ? .succeeded : .rejected))
        let failure: ToolIntentFailure = format == "corrupt" ? .malformedIntent
            : format == "future" ? .unsupportedVersion : .legacyIntentRequiresReapproval
        let expected = state == .succeeded ? "historical result" : failure.resultContent
        #expect(try reopened.toolResult(toolCallID: callID)?.payload == expected)
        let requests = await providerLedger.requestsSnapshot()
        if format == "legacy" {
            #expect(requests.count == 1)
            #expect(requests.first?.messages.contains(.toolResult(toolCallID: "provider-\(callID)", content: expected)) == true)
        } else {
            #expect(requests.isEmpty)
            #expect(try reopened.run(id: runID)?.endReason == .unrecoverable)
        }
    }

    @Test("cold prepared call without admission waits for its displayed approval", .timeLimit(.minutes(1)))
    func coldPreparedCallReapprovesAndContinues() async throws {
        let url = try Fixtures.scratchPath(name: "policy-cold-prepared.sqlite")
        defer { Fixtures.cleanUp(url) }
        let runID = "policy-cold-run", callID = "policy-cold-call"
        let effects = SideEffectLedger()
        let tool = Stage2SideEffectTool(ledger: effects)
        let initialProvider = Stage2ScriptedProvider(ledger: Stage2ProviderLedger(), scripts: [.events([])])
        let original = String(decoding: try JSONEncoder().encode(tool.prepare(callID: callID, argumentsJSON: "{}")), as: UTF8.self)
        do {
            let first = try Stage2GateFixture.makeDiskComponents(at: url)
            var commit = Fixtures.send(conversationID: Stage2GateFixture.conversationID,
                messageID: "user-policy-cold", runID: runID, runState: .preparing)
            commit.conversation = try #require(try first.store.conversation(id: Stage2GateFixture.conversationID))
            commit.run.requestConfigSeed = try initialProvider.makeRequestConfigSeed(instance: first.instance,
                modelID: Stage2GateFixture.modelID, credentialBinding: CredentialBindingSnapshot(
                    reference: Stage2GateFixture.credentialReference, generation: 1))
            try first.store.commitUserTurnAndCreateParentRun(commit)
            let d = tool.descriptor
            let snapshot = RunExecutionSnapshot(providerID: .deepSeek, providerAdapterRevision: initialProvider.adapterRevision,
                prompt: PromptExecutionSnapshot(runtimeSafetyBaseline: PromptTemplateCatalog.currentRuntimeSafetyRevision,
                    zenCore: PromptTemplateCatalog.currentZenCoreRevision, providerAdapterInstructions: ""),
                modelCapabilities: [.text, .streaming, .tools], exposedTools: [ToolExposureSnapshot(
                    toolID: d.id, descriptorRevision: d.revision, displayName: d.displayName,
                    description: d.description, inputSchema: d.inputSchema)], maxProviderSteps: 4)
            try first.store.completeExecutionSnapshot(runID: runID, encodedSnapshot: try ExecutionSnapshotCodec.encode(snapshot))
            try first.store.recordStep(Fixtures.step(stepID: "policy-cold-step", runID: runID))
            try first.store.transitionRun(id: runID, expectedState: .preparing, to: .requestingModel)
            try first.store.transitionRun(id: runID, expectedState: .requestingModel, to: .toolRequested)
            try first.store.transitionRun(id: runID, expectedState: .toolRequested, to: .executingTools)
            try first.store.createToolCall(ToolCallRecord(id: callID, agentRunID: runID, action: d.id,
                state: .prepared, executionIntent: original, attempt: 1, providerCallID: "policy-cold-provider-call",
                batchID: "batch-\(runID)-0-1", batchSequence: 0, createdAt: Fixtures.epoch, updatedAt: Fixtures.epoch))
        }
        let store = try Stage2GateFixture.reopen(url)
        let credentials = CredentialStore(secrets: InMemorySecretBackend(), metadataRepository: InMemoryCredentialMetadataRepository())
        try credentials.provision(SecretValue("stage2-gate-secret"), as: Stage2GateFixture.credentialReference)
        let requests = Stage2ProviderLedger()
        let runtime = ConversationRuntime(store: store, provider: Stage2ScriptedProvider(ledger: requests,
            scripts: [.events([.textDelta("continued"), .finish(.stop)])]), credentials: credentials,
            toolRegistry: try ToolRegistry(tools: [tool]))
        _ = try await runtime.reconcileColdStartRuns()
        var cards: [ToolApprovalProjection] = []
        for _ in 0..<1000 {
            cards = try await runtime.pendingToolApprovals(in: Stage2GateFixture.conversationID)
            if !cards.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let card = try #require(cards.first)
        #expect(card.toolCallID == callID)
        #expect(await effects.snapshot().isEmpty)
        try await runtime.resolveToolApproval(card.request(for: .approveOnce))
        try await Fixtures.awaitRuntimeCompletion(in: store, runtime: runtime, runID: runID)
        #expect(try store.run(id: runID)?.state == .completed)
        #expect(try store.toolCalls(inRun: runID).map(\.id) == [callID])
        #expect(try store.toolCall(id: callID)?.executionIntent == original)
        #expect(try store.toolCall(id: callID)?.state == .succeeded)
        #expect(await effects.snapshot().count == 1)
        #expect(await requests.requestsSnapshot().count == 1)
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
            toolRegistry: try Fixtures.automaticallyAllowedRegistry(in: fixture.store, tools: [CalculatorTool()]))
        let runID = try await runtime.start(I05RuntimeTestFixtures.command())
        try await Fixtures.awaitRuntimeCompletion(in: fixture.store, runtime: runtime, runID: runID)
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

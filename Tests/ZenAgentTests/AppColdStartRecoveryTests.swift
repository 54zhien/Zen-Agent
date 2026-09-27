import Foundation
import Testing

@testable import ZenAgent

@Suite("App cold-start recovery")
@MainActor
struct AppColdStartRecoveryTests {
    @Test("reopened approval waits for the real decision and executes its original call once")
    func reopenedApprovalExecutesOriginalCallOnce() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zen-approval-reopen-\(UUID().uuidString).sqlite")
        let runID = "approval-\(UUID().uuidString)"
        let callID = "call-\(UUID().uuidString)"
        let providerCallID = "provider-\(callID)"
        let ledger = SideEffectLedger()
        let tool = Stage2SideEffectTool(ledger: ledger)

        do {
            let first = try Stage2GateFixture.makeDiskComponents(at: url)
            let provider = Stage2ScriptedProvider(
                ledger: Stage2ProviderLedger(),
                scripts: [.events([])]
            )
            var commit = Fixtures.send(
                conversationID: Stage2GateFixture.conversationID,
                messageID: "user-\(runID)",
                runID: runID,
                runState: .preparing
            )
            commit.conversation = try #require(try first.store.conversation(
                id: Stage2GateFixture.conversationID
            ))
            commit.run.requestConfigSeed = try provider.makeRequestConfigSeed(
                instance: first.instance,
                modelID: Stage2GateFixture.modelID,
                credentialBinding: CredentialBindingSnapshot(
                    reference: Stage2GateFixture.credentialReference,
                    generation: 1
                )
            )
            try first.store.commitUserTurnAndCreateParentRun(commit)
            let descriptor = tool.descriptor
            let snapshot = RunExecutionSnapshot(
                providerID: .deepSeek,
                providerAdapterRevision: provider.adapterRevision,
                prompt: PromptExecutionSnapshot(
                    runtimeSafetyBaseline: PromptTemplateCatalog.currentRuntimeSafetyRevision,
                    zenCore: PromptTemplateCatalog.currentZenCoreRevision,
                    providerAdapterInstructions: ""
                ),
                modelCapabilities: [.text, .streaming, .tools],
                exposedTools: [ToolExposureSnapshot(
                    toolID: descriptor.id,
                    descriptorRevision: descriptor.revision,
                    displayName: descriptor.displayName,
                    description: descriptor.description,
                    inputSchema: descriptor.inputSchema
                )],
                maxProviderSteps: 4
            )
            try first.store.completeExecutionSnapshot(
                runID: runID,
                encodedSnapshot: try ExecutionSnapshotCodec.encode(snapshot)
            )
            try first.store.recordStep(Fixtures.step(stepID: "step-\(runID)", runID: runID))
            try first.store.transitionRun(
                id: runID,
                expectedState: .preparing,
                to: .requestingModel
            )
            try first.store.transitionRun(
                id: runID,
                expectedState: .requestingModel,
                to: .toolRequested
            )
            try first.store.transitionRun(
                id: runID,
                expectedState: .toolRequested,
                to: .waitingForApproval
            )
            let intent = try tool.prepare(callID: callID, argumentsJSON: "{}")
            try first.store.createToolCall(ToolCallRecord(
                id: callID,
                agentRunID: runID,
                action: descriptor.id,
                state: .waitingForApproval,
                executionIntent: String(decoding: try JSONEncoder().encode(intent), as: UTF8.self),
                attempt: 1,
                providerCallID: providerCallID,
                batchID: "batch-\(runID)-0-1",
                batchSequence: 0,
                createdAt: Fixtures.epoch,
                updatedAt: Fixtures.epoch
            ))
        }

        let reopened = try Stage2GateFixture.reopen(url)
        let credentials = CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: InMemoryCredentialMetadataRepository()
        )
        try credentials.provision(
            SecretValue("stage2-gate-secret"),
            as: Stage2GateFixture.credentialReference
        )
        let providerLedger = Stage2ProviderLedger()
        let provider = Stage2ScriptedProvider(
            ledger: providerLedger,
            scripts: [.events([.textDelta("after approval"), .finish(.stop)])]
        )
        let runtime = ConversationRuntime(
            store: reopened,
            provider: provider,
            credentials: credentials,
            toolRegistry: try ToolRegistry(tools: [Stage2SideEffectTool(ledger: ledger)])
        )
        _ = try await runtime.reconcileColdStartRuns()
        let card = try #require(try await runtime.pendingToolApprovals(
            in: Stage2GateFixture.conversationID
        ).first)
        #expect(card.toolCallID == callID)
        #expect((await ledger.snapshot()).isEmpty)
        #expect((await providerLedger.requestsSnapshot()).isEmpty)

        try await runtime.resolveToolApproval(card.request(for: .approveOnce))
        try await runtime.waitForCompletion(runID: runID)

        #expect(try reopened.toolCall(id: callID)?.state == .succeeded)
        #expect(try reopened.run(id: runID)?.state == .completed)
        let observations = await ledger.snapshot()
        #expect(observations.count == 1)
        #expect(observations.first?.idempotencyKey == callID)
        let requests = await providerLedger.requestsSnapshot()
        #expect(requests.count == 1)
        #expect(requests.first?.messages.contains(.toolResult(
            toolCallID: providerCallID,
            content: "succeeded"
        )) == true)
    }

    @Test("a frozen preparing run attaches one real continuation after disk reopen")
    func frozenPreparingRunAttachesContinuation() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zen-prepare-reopen-\(UUID().uuidString).sqlite")
        let runID = "prepare-\(UUID().uuidString)"
        let conversationID = "conversation-\(runID)"
        do {
            let first = PersistenceStore(database: try ZenDatabase.open(at: url.path))
            try first.createProviderInstance(ProviderInstance(
                id: ProviderInstanceID(rawValue: "pi1"),
                providerID: .deepSeek,
                displayName: "DeepSeek",
                baseURL: nil,
                configRevision: ConfigRevision(rawValue: "config-r1"),
                credentialReference: CredentialReference(id: "cred-1")
            ))
            try first.commitUserTurnAndCreateParentRun(Fixtures.send(
                conversationID: conversationID,
                messageID: "user-\(runID)",
                runID: runID,
                runState: .preparing
            ))
            let snapshot = RunExecutionSnapshot(
                providerID: .deepSeek,
                providerAdapterRevision: "stage2-gate-scripted-provider.v1",
                prompt: PromptExecutionSnapshot(
                    runtimeSafetyBaseline: PromptTemplateCatalog.currentRuntimeSafetyRevision,
                    zenCore: PromptTemplateCatalog.currentZenCoreRevision,
                    providerAdapterInstructions: ""
                ),
                modelCapabilities: [.text, .streaming],
                exposedTools: [],
                maxProviderSteps: 4
            )
            try first.completeExecutionSnapshot(
                runID: runID,
                encodedSnapshot: try ExecutionSnapshotCodec.encode(snapshot)
            )
        }

        let reopened = PersistenceStore(database: try ZenDatabase.open(at: url.path))
        let credentials = CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: InMemoryCredentialMetadataRepository()
        )
        try credentials.provision(
            SecretValue("test-only-secret"),
            as: CredentialReference(id: "cred-1")
        )
        let ledger = Stage2ProviderLedger()
        let provider = Stage2ScriptedProvider(
            ledger: ledger,
            scripts: [.events([.textDelta("resumed"), .finish(.stop)])]
        )
        let router = RunEventRouter()
        let runtime = AppAssembly.makeRuntime(
            store: reopened,
            provider: provider,
            credentials: credentials,
            router: router,
            toolRegistry: .empty
        )
        let dependencies = AppAssembly.Dependencies(
            store: reopened,
            credentials: credentials,
            provider: provider,
            runtime: runtime,
            router: router
        )
        let suite = "ZenAgentTests.PrepareRecovery.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let shell = AppShellModel(dependencies: dependencies, userDefaults: defaults)

        for _ in 0..<200 {
            if try reopened.run(id: runID)?.state == .completed,
               shell.launchState == .ready { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let run = try #require(try reopened.run(id: runID))
        #expect(run.id == runID)
        #expect(run.state == .completed)
        #expect(try reopened.steps(inRun: runID).count == 1)
        let requests = await ledger.requestsSnapshot()
        #expect(requests.count == 1)
        #expect(requests.first?.messages.contains(.user("hello")) == true)
    }
}

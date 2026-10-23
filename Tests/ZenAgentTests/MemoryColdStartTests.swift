import Foundation
import GRDB
import Testing
@testable import ZenAgent

@Suite("Memory erasure through the production cold-start coordinator")
struct MemoryColdStartTests {
    @Test(arguments: ["preparing", "approval", "system-consent", "dispatched", "missing-ref"])
    func realColdStartSettlesOriginalOwnerWithoutReplay(checkpoint: String) async throws {
        let url = try Fixtures.scratchPath(name: "memory-cold-\(checkpoint).sqlite")
        defer { Fixtures.cleanUp(url) }
        let effects = SideEffectLedger()
        let tool = Stage2SideEffectTool(ledger: effects)
        let registry = try ToolRegistry(tools: [tool])
        let runID: String
        do {
            let fixture = try MemoryPromptFixture.make(database: ZenDatabase.open(at: url.path), registry: registry)
            let memory = MemoryRuntime(store: fixture.store, credentials: fixture.credentials)
            let item = try memory.save(content: "Windows uses COLD_MEMORY")
            runID = try await fixture.send(text: "Windows help")
            let state: RunState = checkpoint == "preparing" || checkpoint == "missing-ref" ? .preparing : .waitingForApproval
            try fixture.store.database.write { db in
                try db.execute(sql: "UPDATE agentRun SET state=?,endReason=NULL,recoveryAction='resume',activeSlot=conversationID WHERE id=?", arguments: [state.rawValue, runID])
                if state == .preparing { try db.execute(sql: "DELETE FROM agentStep WHERE runID=?", arguments: [runID]) }
            }
            if state != .preparing {
                let intent = try tool.prepare(callID: "cold-call", argumentsJSON: "{}")
                let encoded = String(decoding: try JSONEncoder().encode(intent), as: UTF8.self)
                let callState: ToolCallState = checkpoint == "system-consent" ? .waitingForSystemPermissionConsent : checkpoint == "dispatched" ? .dispatched : .waitingForApproval
                var call = Fixtures.toolCall(id: "cold-call", runID: runID, action: tool.descriptor.id, state: callState, intent: encoded)
                call.providerCallID = "cold-provider-call"; call.batchID = "batch-\(runID)-0-1"; call.batchSequence = 0
                try fixture.store.createToolCall(call)
                if checkpoint == "dispatched" { _ = try await tool.execute(intent, idempotencyKey: call.id) }
            }
            try await memory.delete(id: item.id)
            if checkpoint == "missing-ref" {
                // Missing immutable versions independently revoke a Run even if
                // a legacy lifecycle writer overwrote its invalidate marker.
                try fixture.store.database.write { try $0.execute(sql: "UPDATE agentRun SET recoveryAction='resume' WHERE id=?", arguments: [runID]) }
            }
        }
        let cold = try MemoryPromptFixture.make(database: ZenDatabase.open(at: url.path), registry: registry)
        let report = try await cold.runtime.reconcileColdStartRuns()
        #expect(report.settledRunIDs == [runID])
        #expect(report.failedRunIDs.isEmpty && report.pendingRunIDs.isEmpty)
        let result = try cold.store.run(id: runID)
        #expect(result?.state == .failed)
        #expect(result?.endReason == .dependencyUnavailable)
        #expect(result?.activeSlot == nil)
        #expect(await cold.ledger.requestsSnapshot().isEmpty)
        #expect(await effects.snapshot().count == (checkpoint == "dispatched" ? 1 : 0))
        let retry = try await cold.runtime.retryColdStartRecovery()
        #expect(retry.entries.isEmpty)
        #expect(await cold.ledger.requestsSnapshot().isEmpty)
        if checkpoint == "dispatched" { #expect(try cold.store.toolCall(id: "cold-call")?.state == .indeterminate) }
        _ = try await cold.send(text: "a fresh request after recovery")
    }

    @Test func coldMemoryRevocationConfirmsOriginalManagedFileProofWithoutReplaying() async throws {
        let url = try Fixtures.scratchPath(name: "memory-cold-file-proof.sqlite")
        defer { Fixtures.cleanUp(url) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = ManagedFileStore(applicationSupportRoot: root, protectionRequirement: .bestEffort)
        let runID: String, callID: String
        do {
            let database = try ZenDatabase.open(at: url.path)
            let fileStore = PersistenceStore(database: database)
            let tool = FilesTool(files: files, store: fileStore)
            let fixture = try MemoryPromptFixture.make(database: database, registry: ToolRegistry(tools: [tool]))
            let memory = MemoryRuntime(store: fixture.store, credentials: fixture.credentials)
            let item = try memory.save(content: "Windows uses COLD_FILE_PROOF")
            runID = try await fixture.send(text: "Windows help")
            try fixture.store.database.write { try $0.execute(sql: "UPDATE agentRun SET state='executingTools',endReason=NULL,recoveryAction='resume',activeSlot=conversationID WHERE id=?", arguments: [runID]) }
            let runtime = ToolRuntime(store: fixture.store, registry: try ToolRegistry(tools: [tool]), credentials: fixture.credentials)
            _ = try await runtime.complete(agentRunID: runID, providerCallID: "file-proof", toolID: "files",
                argumentsJSON: #"{"action":"create","displayName":"proof.txt","content":"original effect bytes"}"#,
                batchID: "file-proof-batch", batchSequence: 0)
            let calls = try fixture.store.toolCalls(inRun: runID)
            let call = try #require(calls.first)
            callID = call.id
            let json = try #require(call.executionIntent)
            try runtime.approve(toolCallID: callID, displayedIntentBinding: ToolIntentBinding.make(json))
            try fixture.store.markToolCallPrepared(id: callID)
            _ = try fixture.store.dispatchToolCallWithPolicy(id: callID, expectedAttempt: call.attempt,
                descriptor: tool.descriptor, safetyCap: .unrestricted, checkedIntentBinding: ToolIntentBinding.make(json), at: Date())
            _ = try await tool.execute(ToolIntentCodec.decodeForDisplay(json), idempotencyKey: callID)
            #expect(try fixture.store.toolCall(id: callID)?.state == .dispatched)
            try await memory.delete(id: item.id)
        }
        let database = try ZenDatabase.open(at: url.path)
        let fileStore = PersistenceStore(database: database)
        let registry = try ToolRegistry(tools: [FilesTool(files: files, store: fileStore)])
        let cold = try MemoryPromptFixture.make(database: database, registry: registry)
        let runtime = ConversationRuntime(store: cold.store, provider: cold.provider, credentials: cold.credentials,
            toolRegistry: registry, managedFileStore: files)
        let report = try await runtime.reconcileColdStartRuns()
        #expect(report.settledRunIDs == [runID])
        #expect(try cold.store.run(id: runID)?.endReason == .dependencyUnavailable)
        #expect(try cold.store.run(id: runID)?.activeSlot == nil)
        #expect(try cold.store.toolCall(id: callID)?.state == .succeeded)
        #expect(try cold.store.toolResult(toolCallID: callID) != nil)
        #expect(try cold.store.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM fileAsset") } == 1)
        #expect(await cold.ledger.requestsSnapshot().isEmpty)
        let retry = try await runtime.retryColdStartRecovery()
        #expect(retry.entries.isEmpty)
    }
}

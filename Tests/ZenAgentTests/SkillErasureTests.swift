import Foundation
import GRDB
import Testing
@testable import ZenAgent

@Suite("Stage8 Skill and Environment erasure through cold-start recovery")
struct SkillErasureTests {
    @Test("a revoked frozen Skill settles its original owner and confirms dispatched file proof without replay")
    func coldSkillRevocationPreservesFileProof() async throws {
        let url = try Fixtures.scratchPath(name: "skill-cold-file-proof.sqlite")
        defer { Fixtures.cleanUp(url) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = ManagedFileStore(applicationSupportRoot: root, protectionRequirement: .bestEffort)
        let runID: String, callID: String
        let runSnapshot: String
        do {
            let database = try ZenDatabase.open(at: url.path)
            let store = PersistenceStore(database: database)
            let fileTool = FilesTool(files: files, store: store)
            let registry = try ToolRegistry(tools: [fileTool])
            let fixture = try MemoryPromptFixture.make(database: database, registry: registry)
            runID = try await fixture.send(text: "Create the requested proof file")
            #expect(await fixture.ledger.requestsSnapshot().count == 1)

            // Model a file call that crossed the real dispatch boundary before the
            // owning Skill was erased. Recovery must confirm this proof, never replay.
            try store.database.write { db in
                try db.execute(sql: "UPDATE agentRun SET state='executingTools',endReason=NULL,recoveryAction='resume',activeSlot=conversationID WHERE id=?", arguments: [runID])
            }
            let toolRuntime = ToolRuntime(store: store, registry: registry, credentials: fixture.credentials)
            _ = try await toolRuntime.complete(agentRunID: runID, providerCallID: "skill-file-proof",
                toolID: fileTool.descriptor.id,
                argumentsJSON: #"{"action":"create","displayName":"skill-proof.txt","content":"original effect bytes"}"#,
                batchID: "skill-file-proof-batch", batchSequence: 0)
            let call = try #require(try store.toolCalls(inRun: runID).first)
            callID = call.id
            let intentJSON = try #require(call.executionIntent)
            try toolRuntime.approve(toolCallID: callID, displayedIntentBinding: ToolIntentBinding.make(intentJSON))
            try store.markToolCallPrepared(id: callID)
            _ = try store.dispatchToolCallWithPolicy(id: callID, expectedAttempt: call.attempt,
                descriptor: fileTool.descriptor, safetyCap: .unrestricted,
                checkedIntentBinding: ToolIntentBinding.make(intentJSON), at: Date())
            _ = try await fileTool.execute(ToolIntentCodec.decodeForDisplay(intentJSON), idempotencyKey: callID)
            #expect(try store.toolCall(id: callID)?.state == .dispatched)

            // A content-free, valid v2 Skill identity whose backing definition has
            // already been removed exercises missing-reference recovery directly.
            let storedRun = try #require(store.run(id: runID))
            let encoded = try #require(storedRun.executionSnapshot)
            runSnapshot = try snapshotByAddingRevokedSkillReference(encoded)
            try store.database.write { db in
                try db.execute(sql: "UPDATE agentRun SET executionSnapshot=?,state='suspended',suspendReason='backgrounded',recoveryAction='resume',activeSlot=conversationID WHERE id=?", arguments: [runSnapshot, runID])
            }
        }

        let database = try ZenDatabase.open(at: url.path)
        let reopenedStore = PersistenceStore(database: database)
        let registry = try ToolRegistry(tools: [FilesTool(files: files, store: reopenedStore)])
        let cold = try MemoryPromptFixture.make(database: database, registry: registry)
        let runtime = ConversationRuntime(store: reopenedStore, provider: cold.provider,
            credentials: cold.credentials, toolRegistry: registry, managedFileStore: files)
        let report = try await runtime.reconcileColdStartRuns()

        #expect(report.settledRunIDs == [runID])
        #expect(report.failedRunIDs.isEmpty && report.pendingRunIDs.isEmpty)
        #expect(try reopenedStore.run(id: runID)?.state == .failed)
        #expect(try reopenedStore.run(id: runID)?.endReason == .dependencyUnavailable)
        #expect(try reopenedStore.run(id: runID)?.activeSlot == nil)
        #expect(try reopenedStore.toolCall(id: callID)?.state == .succeeded)
        #expect(try reopenedStore.toolResult(toolCallID: callID) != nil)
        #expect(try reopenedStore.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM fileAsset") } == 1)
        #expect(await cold.ledger.requestsSnapshot().isEmpty)
        let retry = try await runtime.retryColdStartRecovery()
        #expect(retry.entries.isEmpty)
    }

    private func snapshotByAddingRevokedSkillReference(_ encoded: String) throws -> String {
        let decoded = try JSONSerialization.jsonObject(with: Data(encoded.utf8))
        var snapshot = try #require(decoded as? [String: Any])
        snapshot["formatVersion"] = 2
        var prompt = try #require(snapshot["prompt"] as? [String: Any])
        prompt["skillReferences"] = [[
            "skillID": "already-erased-skill",
            "revisionID": "erased-revision",
            "environmentReferences": [],
            "environmentFingerprint": "env-v1:" + String(repeating: "0", count: 64)
        ]]
        snapshot["prompt"] = prompt
        return String(decoding: try JSONSerialization.data(withJSONObject: snapshot), as: UTF8.self)
    }
}

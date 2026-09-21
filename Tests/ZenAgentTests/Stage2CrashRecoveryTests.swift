import Foundation
import GRDB
import XCTest

@testable import ZenAgent

/// I08 RED integration contract: a crash after dispatch must not duplicate an
/// external write when a fresh runtime recovers the same durable database.
final class Stage2CrashRecoveryTests: XCTestCase {

    func testCrashAfterDispatchReopenRecoverKeepsDispatchCountAtOne() async throws {
        let url = try Fixtures.scratchPath(name: "i08-crash-recovery.sqlite")
        defer { Fixtures.cleanUp(url) }

        let ledger = SideEffectLedger()
        let callID = "call-crash-window"
        let runID = "run-crash-window"

        do {
            let store = PersistenceStore(
                database: try ZenDatabase.open(
                    at: url.path(),
                    migrator: Migrations.makeMigrator()
                )
            )
            try store.commitUserTurnAndCreateParentRun(
                Fixtures.send(
                    conversationID: "conversation-crash-window",
                    messageID: "message-crash-window",
                    runID: runID,
                    runState: .executingTools
                )
            )

            let tool = Stage2SideEffectTool(ledger: ledger)
            let intent = try tool.prepare(callID: callID, argumentsJSON: "{}")
            try store.createToolCall(
                toolCall(
                    id: callID,
                    runID: runID,
                    state: .prepared,
                    intent: intent
                )
            )

            // The marker is the last durable write before the external call.
            try store.markToolCallDispatched(id: callID)
            _ = try await tool.execute(intent, idempotencyKey: callID)

            let observations = await ledger.snapshot()
            XCTAssertEqual(observations.count, 1)
            XCTAssertEqual(try store.toolCall(id: callID)?.state, .dispatched)
            XCTAssertNil(try store.toolResult(toolCallID: callID))
        }

        // A new PersistenceStore and ToolRuntime stand in for a new process.
        let reopened = PersistenceStore(
            database: try ZenDatabase.open(
                at: url.path(),
                migrator: Migrations.makeMigrator()
            )
        )
        let runtime = try ToolRuntime(
            store: reopened,
            registry: ToolRegistry(tools: [Stage2SideEffectTool(ledger: ledger)])
        )

        try await makeRecovery(
            store: reopened,
            toolRuntime: runtime
        ).recover(runID: runID)

        let observations = await ledger.snapshot()
        XCTAssertEqual(
            observations.count,
            1,
            "recover must not call the executor for a dispatched ToolCall"
        )
        XCTAssertEqual(try reopened.toolCall(id: callID)?.state, .indeterminate)
        XCTAssertEqual(try reopened.run(id: runID)?.state, .failed)
        XCTAssertEqual(
            try reopened.run(id: runID)?.endReason,
            EndReason.toolOutcomeUnknown
        )
        XCTAssertNil(try reopened.toolResult(toolCallID: callID))

        // A late completion from the old process cannot overwrite the recovery
        // conclusion because the durable CAS requires state == dispatched.
        XCTAssertThrowsError(
            try reopened.finishDispatchedToolCall(
                id: callID,
                expectedAttempt: 1,
                state: .succeeded,
                result: ToolResultRecord(
                    toolCallID: callID,
                    payload: "late completion",
                    createdAt: Fixtures.epoch
                )
            )
        )
        XCTAssertEqual(try reopened.toolCall(id: callID)?.state, .indeterminate)
        let finalObservations = await ledger.snapshot()
        XCTAssertEqual(finalObservations.first?.dispatchCount, 1)
    }

    private func makeRecovery(
        store: PersistenceStore,
        toolRuntime: ToolRuntime
    ) -> RunRecovery {
        RunRecovery(store: store, toolRuntime: toolRuntime)
    }

    private func toolCall(
        id: String,
        runID: String,
        state: ToolCallState,
        intent: ToolExecutionIntent
    ) throws -> ToolCallRecord {
        let data = try JSONEncoder().encode(intent)
        return Fixtures.toolCall(
            id: id,
            runID: runID,
            action: "stage2_side_effect",
            state: state,
            intent: String(decoding: data, as: UTF8.self)
        )
    }
}

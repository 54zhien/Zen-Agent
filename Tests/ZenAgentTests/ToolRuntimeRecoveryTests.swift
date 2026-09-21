import Foundation
import XCTest

@testable import ZenAgent

/// I08 RED contract tests for ToolCall recovery and the dispatch crash window.
final class ToolRuntimeRecoveryTests: XCTestCase {

    func testDispatchedCallBecomesIndeterminateWithoutExecutingAgain() async throws {
        let store = try makeStore()
        let runID = try makeRun(in: store)
        let ledger = SideEffectLedger()
        let tool = Stage2SideEffectTool(ledger: ledger)
        let runtime = try ToolRuntime(
            store: store,
            registry: ToolRegistry(tools: [tool])
        )
        let callID = "dispatched-\(runID)"
        let intent = try tool.prepare(callID: callID, argumentsJSON: "{}")
        try store.createToolCall(
            toolCall(
                id: callID,
                runID: runID,
                state: .prepared,
                intent: intent
            )
        )
        try store.markToolCallDispatched(id: callID)

        // Simulate the external side effect landing after the durable marker but
        // before the ToolResult transaction.
        _ = try await tool.execute(intent, idempotencyKey: callID)
        let beforeRecovery = await ledger.snapshot()
        XCTAssertEqual(beforeRecovery.count, 1)
        XCTAssertNil(try store.toolResult(toolCallID: callID))

        try await makeRecovery(store: store, toolRuntime: runtime).recover(runID: runID)

        let afterRecovery = await ledger.snapshot()
        XCTAssertEqual(afterRecovery.count, 1, "recovery must not execute again")
        XCTAssertEqual(try store.toolCall(id: callID)?.state, .indeterminate)
        XCTAssertEqual(try store.run(id: runID)?.state, .failed)
        XCTAssertEqual(try store.run(id: runID)?.endReason, EndReason.toolOutcomeUnknown)
    }

    func testIndeterminateCallRemainsIndeterminateAndIsNotRetried() async throws {
        let store = try makeStore()
        let runID = try makeRun(in: store)
        let ledger = SideEffectLedger()
        let tool = Stage2SideEffectTool(ledger: ledger)
        let runtime = try ToolRuntime(
            store: store,
            registry: ToolRegistry(tools: [tool])
        )
        let callID = "indeterminate-\(runID)"
        let intent = try tool.prepare(callID: callID, argumentsJSON: "{}")
        try store.createToolCall(
            toolCall(
                id: callID,
                runID: runID,
                state: .indeterminate,
                intent: intent
            )
        )

        try await makeRecovery(store: store, toolRuntime: runtime).recover(runID: runID)

        let observations = await ledger.snapshot()
        XCTAssertEqual(observations.count, 0)
        XCTAssertEqual(try store.toolCall(id: callID)?.state, .indeterminate)
    }

    func testValidatedApprovedAndPreparedCallsAreMayDispatchOnly() async throws {
        for state in [ToolCallState.validated, .approved, .prepared] {
            let store = try makeStore()
            let runID = try makeRun(in: store)
            let ledger = SideEffectLedger()
            let tool = Stage2SideEffectTool(ledger: ledger)
            let runtime = try ToolRuntime(
                store: store,
                registry: ToolRegistry(tools: [tool])
            )
            let callID = "\(state.rawValue)-\(runID)"
            let intent = try tool.prepare(callID: callID, argumentsJSON: "{}")
            try store.createToolCall(
                toolCall(
                    id: callID,
                    runID: runID,
                    state: state,
                    intent: intent
                )
            )

            let pending = try store.toolCallsNeedingRecovery(inRun: runID)
            XCTAssertEqual(pending.first?.disposition, .mayDispatch)

            try await makeRecovery(store: store, toolRuntime: runtime).recover(runID: runID)

            let observations = await ledger.snapshot()
            XCTAssertEqual(observations.count, 0)
            XCTAssertNotEqual(try store.toolCall(id: callID)?.state, .indeterminate)
        }
    }

    func testSettledToolResultsAreReusedWithoutAnotherExecutorCall() async throws {
        let store = try makeStore()
        let runID = try makeRun(in: store)
        let ledger = SideEffectLedger()
        let tool = Stage2SideEffectTool(ledger: ledger)
        let runtime = try ToolRuntime(
            store: store,
            registry: ToolRegistry(tools: [tool])
        )
        let callID = "settled-\(runID)"
        let intent = try tool.prepare(callID: callID, argumentsJSON: "{}")
        try store.createToolCall(
            toolCall(
                id: callID,
                runID: runID,
                state: .succeeded,
                intent: intent
            )
        )
        try store.database.write { db in
            try ToolResultRecord(
                toolCallID: callID,
                payload: "already complete",
                createdAt: Fixtures.epoch
            ).insert(db)
        }

        try await makeRecovery(store: store, toolRuntime: runtime).recover(runID: runID)

        let observations = await ledger.snapshot()
        XCTAssertEqual(observations.count, 0)
        XCTAssertEqual(try store.toolCall(id: callID)?.state, .succeeded)
        XCTAssertEqual(
            try store.toolResult(toolCallID: callID)?.payload,
            "already complete"
        )
    }

    func testRecoveryNeverChoosesRestartForAnUnknownToolOutcome() async throws {
        let store = try makeStore()
        let runID = try makeRun(in: store)
        let callID = "restart-forbidden-\(runID)"
        try store.createToolCall(
            toolCall(
                id: callID,
                runID: runID,
                state: .indeterminate,
                intent: nil
            )
        )

        try await makeRecovery(store: store).recover(runID: runID)

        let run = try XCTUnwrap(try store.run(id: runID))
        XCTAssertNotEqual(run.recoveryAction, RecoveryAction.restart)
        XCTAssertEqual(run.endReason, EndReason.toolOutcomeUnknown)
    }

    private func makeStore() throws -> PersistenceStore {
        PersistenceStore(database: try ZenDatabase.inMemory())
    }

    @discardableResult
    private func makeRun(
        in store: PersistenceStore,
        runID: String = "run-tool-recovery-\(UUID().uuidString)"
    ) throws -> String {
        try store.commitUserTurnAndCreateParentRun(
            Fixtures.send(
                conversationID: "conversation-\(runID)",
                messageID: "message-\(runID)",
                runID: runID,
                runState: .executingTools
            )
        )
        return runID
    }

    private func makeRecovery(
        store: PersistenceStore,
        toolRuntime: ToolRuntime? = nil
    ) -> RunRecovery {
        RunRecovery(store: store, toolRuntime: toolRuntime)
    }

    private func toolCall(
        id: String,
        runID: String,
        state: ToolCallState,
        intent: ToolExecutionIntent?
    ) -> ToolCallRecord {
        var call = Fixtures.toolCall(
            id: id,
            runID: runID,
            action: "stage2_side_effect",
            state: state,
            intent: encoded(intent)
        )
        call.batchID = "batch-\(runID)"
        call.batchSequence = 0
        return call
    }

    private func encoded(_ intent: ToolExecutionIntent?) -> String? {
        guard let intent else { return nil }
        guard let data = try? JSONEncoder().encode(intent) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

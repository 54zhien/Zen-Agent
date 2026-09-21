import Foundation
import GRDB
import XCTest

@testable import ZenAgent

final class ToolRuntimeTests: XCTestCase {
    func testFinishDispatchedToolCallCannotOverwriteRecoveredIndeterminate() throws {
        let database = try makeMigratedDatabase()
        try insertRun(into: database, runID: "run-cas")
        let store = try PersistenceStore(database: database)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let call = ToolCallRecord(
            id: "call-cas",
            agentRunID: "run-cas",
            action: "side_effect",
            state: .dispatched,
            executionIntent: "{}",
            attempt: 1,
            providerCallID: "provider-cas",
            batchID: "batch-cas",
            batchSequence: 0,
            createdAt: now,
            updatedAt: now
        )
        try store.createToolCall(call)
        try store.finishToolCall(id: call.id, state: ToolCallState.indeterminate, at: now)

        XCTAssertThrowsError(
            try store.finishDispatchedToolCall(
                id: call.id,
                expectedAttempt: 1,
                state: ToolCallState.succeeded,
                result: ToolResultRecord(
                    toolCallID: call.id,
                    payload: "late",
                    createdAt: now
                ),
                at: now
            )
        )
        XCTAssertEqual(try store.toolCall(id: call.id)?.state, ToolCallState.indeterminate)
        XCTAssertNil(try store.toolResult(toolCallID: call.id))
    }

    func testToolRuntimeUsesStableToolCallIDAndPersistsResult() async throws {
        let database = try makeMigratedDatabase()
        try insertRun(into: database, runID: "run-runtime")
        let store = try PersistenceStore(database: database)
        let observation = I06SideEffectObservation()
        let registry = try ToolRegistry(tools: [I06SideEffectTool(observation: observation)])
        let runtime = ToolRuntime(store: store, registry: registry)

        let result = try await runtime.complete(
            agentRunID: "run-runtime",
            providerCallID: "provider-runtime",
            toolID: "side_effect",
            argumentsJSON: "{}",
            batchID: "batch-runtime",
            batchSequence: 2
        )

        XCTAssertEqual(result?.content, "side effect complete")
        let calls = try store.toolCalls(inRun: "run-runtime")
        XCTAssertEqual(calls.count, 1)
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.state, ToolCallState.succeeded)
        XCTAssertEqual(call.providerCallID, "provider-runtime")
        XCTAssertEqual(call.batchID, "batch-runtime")
        XCTAssertEqual(call.batchSequence, 2)
        let idempotencyKeys = await observation.idempotencyKeys()
        XCTAssertEqual(idempotencyKeys, [call.id])
        XCTAssertEqual(
            try store.toolResult(toolCallID: call.id)?.payload,
            "side effect complete"
        )
    }

    func testApprovalMovesTheSameCallToApprovedWithoutAutoExecution() async throws {
        let database = try makeMigratedDatabase()
        try insertRun(into: database, runID: "run-approval")
        let store = try PersistenceStore(database: database)
        let observation = I06SideEffectObservation()
        let registry = try ToolRegistry(
            tools: [I06SideEffectTool(observation: observation, approval: .required)]
        )
        let runtime = ToolRuntime(store: store, registry: registry)

        let result = try await runtime.complete(
            agentRunID: "run-approval",
            providerCallID: "provider-approval",
            toolID: "side_effect",
            argumentsJSON: "{}",
            batchID: "batch-approval",
            batchSequence: 0
        )
        XCTAssertNil(result)

        let waiting = try XCTUnwrap(try store.toolCalls(inRun: "run-approval").first)
        XCTAssertEqual(waiting.state, ToolCallState.waitingForApproval)
        try runtime.approve(toolCallID: waiting.id)

        let approved: ToolCallRecord = try XCTUnwrap(try store.toolCall(id: waiting.id))
        XCTAssertEqual(approved.id, waiting.id)
        XCTAssertEqual(approved.state, ToolCallState.approved)
        let dispatchCount = await observation.dispatchCount()
        XCTAssertEqual(dispatchCount, 0)
    }

    func testRejectPersistsModelVisibleResultOnTheSameCall() async throws {
        let database = try makeMigratedDatabase()
        try insertRun(into: database, runID: "run-reject")
        let store = try PersistenceStore(database: database)
        let observation = I06SideEffectObservation()
        let registry = try ToolRegistry(
            tools: [I06SideEffectTool(observation: observation, approval: .required)]
        )
        let runtime = ToolRuntime(store: store, registry: registry)

        _ = try await runtime.complete(
            agentRunID: "run-reject",
            providerCallID: "provider-reject",
            toolID: "side_effect",
            argumentsJSON: "{}",
            batchID: "batch-reject",
            batchSequence: 0
        )
        let waiting: ToolCallRecord = try XCTUnwrap(try store.toolCalls(inRun: "run-reject").first)

        let rejection = try runtime.reject(toolCallID: waiting.id)
        let settled: ToolCallRecord = try XCTUnwrap(try store.toolCall(id: waiting.id))
        XCTAssertEqual(settled.id, waiting.id)
        XCTAssertEqual(settled.state, ToolCallState.rejected)
        XCTAssertEqual(
            try store.toolResult(toolCallID: waiting.id)?.payload,
            rejection.content
        )
        let dispatchCount = await observation.dispatchCount()
        XCTAssertEqual(dispatchCount, 0)
    }
}

extension MigrationTests {
    func testV6ToV7PreservesExistingToolCalls() throws {
        let database = try DatabaseQueue()
        var v6Migrator = DatabaseMigrator()
        Migrations.registerV1(&v6Migrator)
        Migrations.registerV2(&v6Migrator)
        Migrations.registerV3(&v6Migrator)
        Migrations.registerV4(&v6Migrator)
        Migrations.registerV5(&v6Migrator)
        Migrations.registerV6(&v6Migrator)
        try v6Migrator.migrate(database)

        let oldDate = Date(timeIntervalSince1970: 1_600_000_000)
        try database.write { db in
            try insertRun(into: db, runID: "run-v6")
            try db.execute(
                sql: """
                INSERT INTO toolCall
                    (id, agentRunID, action, state, executionIntent, attempt, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: StatementArguments([
                    "call-v6", "run-v6", "legacy", ToolCallState.prepared.rawValue,
                    "{}", 1, oldDate, oldDate,
                ])
            )
        }

        try Migrations.makeMigrator().migrate(database)

        let oldCall = try database.read { db in
            try ToolCallRecord.fetchOne(db, key: "call-v6")
        }
        XCTAssertEqual(oldCall?.id, "call-v6")
        XCTAssertNil(oldCall?.providerCallID)
        XCTAssertNil(oldCall?.batchID)
        XCTAssertNil(oldCall?.batchSequence)
        XCTAssertTrue(try database.read { db in try db.tableExists("toolResult") })

        let newCall = ToolCallRecord(
            id: "call-v7",
            agentRunID: "run-v6",
            action: "stage2",
            state: .succeeded,
            executionIntent: "{}",
            attempt: 1,
            providerCallID: "provider-v7",
            batchID: "batch-v7",
            batchSequence: 4,
            createdAt: oldDate,
            updatedAt: oldDate
        )
        let newResult = ToolResultRecord(
            toolCallID: newCall.id,
            payload: "round trip",
            createdAt: oldDate
        )
        try database.write { db in
            try newCall.insert(db)
            try newResult.insert(db)
        }

        let roundTrip = try database.read { db in
            (
                try ToolCallRecord.fetchOne(db, key: newCall.id),
                try ToolResultRecord.fetchOne(db, key: newCall.id)
            )
        }
        XCTAssertEqual(roundTrip.0?.providerCallID, "provider-v7")
        XCTAssertEqual(roundTrip.0?.batchID, "batch-v7")
        XCTAssertEqual(roundTrip.0?.batchSequence, 4)
        XCTAssertEqual(roundTrip.1?.payload, "round trip")
    }
}

private actor I06SideEffectObservation {
    private var keys: [String] = []

    func record(idempotencyKey: String) {
        keys.append(idempotencyKey)
    }

    func idempotencyKeys() -> [String] {
        keys
    }

    func dispatchCount() -> Int {
        keys.count
    }
}

private struct I06SideEffectTool: ToolExecutable {
    let descriptor: ToolDescriptor
    private let observation: I06SideEffectObservation

    init(
        observation: I06SideEffectObservation,
        approval: ToolApprovalRequirement = .notRequired
    ) {
        self.observation = observation
        self.descriptor = ToolDescriptor(
            id: "side_effect",
            displayName: "Side Effect",
            description: "A test side effect.",
            inputSchema: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
            ]),
            revision: "1",
            sideEffect: .externalWrite,
            approvalRequirement: approval
        )
    }

    func prepare(callID: String, argumentsJSON: String) throws -> ToolExecutionIntent {
        _ = callID
        guard argumentsJSON == "{}" else {
            throw ToolExecutionError.invalidArguments
        }
        return ToolExecutionIntent(
            formatVersion: ToolExecutionIntent.currentFormatVersion,
            toolID: descriptor.id,
            descriptorRevision: descriptor.revision,
            normalizedArgumentsJSON: "{}",
            targetIdentity: "test-target",
            destinationIdentity: "test-destination"
        )
    }

    func execute(
        _ intent: ToolExecutionIntent,
        idempotencyKey: String
    ) async throws -> ToolExecutionResult {
        guard
            intent.toolID == descriptor.id,
            intent.descriptorRevision == descriptor.revision
        else {
            throw ToolExecutionError.invalidIntent
        }
        await observation.record(idempotencyKey: idempotencyKey)
        return ToolExecutionResult(content: "side effect complete")
    }
}

private func makeMigratedDatabase() throws -> ZenDatabase {
    try ZenDatabase.inMemory()
}

private func insertRun(into database: ZenDatabase, runID: String) throws {
    try database.write { db in
        try insertRun(into: db, runID: runID)
    }
}

private func insertRun(into db: Database, runID: String) throws {
    let conversationID = runID + "-conversation"
    try Fixtures.conversation(id: conversationID).insert(db)
    try Fixtures.run(id: runID, conversationID: conversationID).insert(db)
}

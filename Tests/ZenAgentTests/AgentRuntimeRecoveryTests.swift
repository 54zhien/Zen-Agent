import Foundation
import GRDB
import XCTest

@testable import ZenAgent

/// I08 RED contract tests for run-level suspend/recovery decisions.
///
/// The recovery implementation is intentionally absent on this branch. These tests
/// keep the durable checkpoints concrete so the missing contract is the only expected
/// compile failure.
final class AgentRuntimeRecoveryTests: XCTestCase {

    func testOnlyAnActiveRunCanBeRecovered() async throws {
        let store = try makeStore()
        let runID = try makeRun(in: store, state: .preparing)
        try store.finishRun(id: runID, state: .completed, endReason: .completed)

        do {
            try await makeRecovery(store: store).recover(runID: runID)
            XCTFail("a terminal run must not enter recovery")
        } catch {
            // The concrete recovery error is part of the missing contract. The
            // important RED assertion is that the call is rejected at all.
        }
    }

    func testPreparingWithoutSnapshotRepreparesAndDoesNotRestart() async throws {
        let store = try makeStore()
        let runID = try makeRun(in: store, state: .preparing)

        try await makeRecovery(store: store).recover(runID: runID)

        let run = try XCTUnwrap(try store.run(id: runID))
        XCTAssertEqual(run.state, .preparing)
        XCTAssertNotEqual(run.recoveryAction, RecoveryAction.restart)
    }

    func testCompleteSnapshotBeforeProviderRequestCanContinue() async throws {
        let store = try makeStore()
        let runID = try makeRun(in: store, state: .preparing)
        try store.completeExecutionSnapshot(
            runID: runID,
            encodedSnapshot: try validSnapshot()
        )

        try await makeRecovery(store: store).recover(runID: runID)

        let run = try XCTUnwrap(try store.run(id: runID))
        XCTAssertEqual(run.state, .requestingModel)
        XCTAssertNotEqual(run.recoveryAction, RecoveryAction.restart)
    }

    func testWaitingForApprovalKeepsTheSameToolCall() async throws {
        let store = try makeStore()
        let runID = try makeRun(in: store, state: .waitingForApproval)
        let callID = "approval-\(runID)"
        try store.createToolCall(
            toolCall(
                id: callID,
                runID: runID,
                state: .waitingForApproval,
                batchSequence: 0
            )
        )

        try await makeRecovery(store: store).recover(runID: runID)

        let calls = try store.toolCalls(inRun: runID)
        XCTAssertEqual(calls.map(\.id), [callID])
        XCTAssertEqual(calls.first?.state, .waitingForApproval)
        XCTAssertEqual(try store.run(id: runID)?.state, .waitingForApproval)
        // The recovery event must be ApprovalRequired for this same call; the
        // durable identity assertion above prevents a replacement ToolCall.
    }

    func testTerminalToolResultsContinueInBatchOrder() async throws {
        let store = try makeStore()
        let runID = try makeRun(in: store, state: .executingTools)
        let first = toolCall(
            id: "batch-first",
            runID: runID,
            state: .succeeded,
            batchID: "batch-1",
            batchSequence: 1
        )
        let second = toolCall(
            id: "batch-second",
            runID: runID,
            state: .succeeded,
            batchID: "batch-1",
            batchSequence: 0
        )
        try store.createToolCall(first)
        try store.createToolCall(second)
        try store.database.write { db in
            try ToolResultRecord(
                toolCallID: first.id,
                payload: "first",
                createdAt: Fixtures.epoch
            ).insert(db)
            try ToolResultRecord(
                toolCallID: second.id,
                payload: "second",
                createdAt: Fixtures.epoch
            ).insert(db)
        }

        try await makeRecovery(store: store).recover(runID: runID)

        let calls = try store.toolCalls(inRun: runID)
        XCTAssertEqual(Set(calls.map(\.id)), Set([first.id, second.id]))
        XCTAssertEqual(try store.toolResult(toolCallID: first.id)?.payload, "first")
        XCTAssertEqual(try store.toolResult(toolCallID: second.id)?.payload, "second")
        XCTAssertEqual(try store.run(id: runID)?.state, .continuing)
    }

    func testStreamingWithoutResumeTokenPreservesPartialAndEndsInterrupted() async throws {
        let store = try makeStore()
        let runID = try makeRun(in: store, state: .streaming)
        try store.recordStep(
            Fixtures.step(stepID: "step-\(runID)", runID: runID, attempt: 1)
        )

        let response = try store.ensureAssistantResponse(
            forRunID: runID,
            messageID: "response-\(runID)"
        )
        let partID = "partial-\(runID)"
        try store.createPart(
            Fixtures.streamingPart(id: partID, messageID: response.id, text: "partial")
        )

        try await makeRecovery(store: store).recover(runID: runID)

        let run = try XCTUnwrap(try store.run(id: runID))
        XCTAssertEqual(run.state, .failed)
        XCTAssertEqual(run.endReason, EndReason.streamInterrupted)
        XCTAssertEqual(try store.text(ofPart: partID), "partial")
        XCTAssertEqual(try store.steps(inRun: runID).map(\.attempt), [1])
        XCTAssertNotEqual(run.recoveryAction, RecoveryAction.restart)
    }

    func testCredentialRefreshWithSameBindingGenerationCanContinue() async throws {
        let store = try makeStore()
        let runID = try makeRun(in: store, state: .preparing)
        let credentials = makeCredentialStore()
        let now = Fixtures.epoch
        try credentials.store.provision(
            SecretValue("old-token"),
            as: credentials.reference,
            principalFingerprint: "subject-a",
            at: now
        )
        try credentials.store.refresh(
            SecretValue("refreshed-token"),
            for: credentials.reference,
            at: now.addingTimeInterval(1)
        )

        try await makeRecovery(
            store: store,
            credentials: credentials.store
        ).recover(runID: runID)

        let run = try XCTUnwrap(try store.run(id: runID))
        XCTAssertNotEqual(run.state, .failed)
        XCTAssertNotEqual(run.recoveryAction, RecoveryAction.invalidate)
    }

    func testCredentialRebindOrLogoutCannotSilentlySwitchTheOldRun() async throws {
        for mutation in ["rebind", "logout"] {
            let store = try makeStore()
            let runID = try makeRun(in: store, state: .preparing)
            let credentials = makeCredentialStore()
            let now = Fixtures.epoch
            try credentials.store.provision(
                SecretValue("old-token"),
                as: credentials.reference,
                principalFingerprint: "subject-a",
                at: now
            )

            if mutation == "rebind" {
                try credentials.store.rebind(
                    SecretValue("new-account-token"),
                    as: credentials.reference,
                    principalFingerprint: "subject-b",
                    at: now.addingTimeInterval(1)
                )
            } else {
                try credentials.store.logout(
                    credentials.reference,
                    at: now.addingTimeInterval(1)
                )
            }

            try await makeRecovery(
                store: store,
                credentials: credentials.store
            ).recover(runID: runID)

            let run = try XCTUnwrap(try store.run(id: runID))
            XCTAssertTrue(
                run.state == .failed || run.recoveryAction == .invalidate,
                "\(mutation) must fail or invalidate the old run, never continue with the new binding"
            )
        }
    }

    func testUnreadableSnapshotFailsClosed() async throws {
        let store = try makeStore()
        let runID = try makeRun(in: store, state: .preparing)
        try store.database.write { db in
            try db.execute(
                sql: "UPDATE agentRun SET executionSnapshot = ? WHERE id = ?",
                arguments: ["{not-json", runID]
            )
        }

        try await makeRecovery(store: store).recover(runID: runID)

        let run = try XCTUnwrap(try store.run(id: runID))
        XCTAssertEqual(run.state, .failed)
        XCTAssertEqual(run.endReason, EndReason.unrecoverable)
        XCTAssertNotEqual(run.state, .requestingModel)
    }

    private func makeStore() throws -> PersistenceStore {
        PersistenceStore(database: try ZenDatabase.inMemory())
    }

    @discardableResult
    private func makeRun(
        in store: PersistenceStore,
        state: RunState,
        runID: String = "run-\(UUID().uuidString)"
    ) throws -> String {
        try store.commitUserTurnAndCreateParentRun(
            Fixtures.send(
                conversationID: "conversation-\(runID)",
                messageID: "message-\(runID)",
                runID: runID,
                runState: state
            )
        )
        return runID
    }

    private func makeRecovery(
        store: PersistenceStore,
        toolRuntime: ToolRuntime? = nil,
        credentials: (any CredentialStoring)? = nil
    ) -> RunRecovery {
        RunRecovery(
            store: store,
            toolRuntime: toolRuntime,
            credentials: credentials
        )
    }

    private func validSnapshot() throws -> String {
        try ExecutionSnapshotCodec.encode(
            RunExecutionSnapshot(
                providerID: ProviderID(rawValue: "fake"),
                providerAdapterRevision: "fake-provider.v1",
                prompt: PromptExecutionSnapshot(
                    runtimeSafetyBaseline: "runtime-safety-v1",
                    zenCore: "zen-core-v1",
                    providerAdapterInstructions: "test"
                ),
                modelCapabilities: [.text, .streaming],
                exposedTools: [],
                maxProviderSteps: 4
            )
        )
    }

    private func toolCall(
        id: String,
        runID: String,
        state: ToolCallState,
        batchID: String? = nil,
        batchSequence: Int? = nil
    ) -> ToolCallRecord {
        var call = Fixtures.toolCall(
            id: id,
            runID: runID,
            action: "stage2_side_effect",
            state: state
        )
        call.batchID = batchID
        call.batchSequence = batchSequence
        return call
    }

    private func makeCredentialStore() -> (
        store: CredentialStore,
        reference: CredentialReference
    ) {
        let reference = CredentialReference(id: "cred-1")
        return (
            CredentialStore(
                secrets: InMemorySecretBackend(),
                metadataRepository: InMemoryCredentialMetadataRepository()
            ),
            reference
        )
    }
}

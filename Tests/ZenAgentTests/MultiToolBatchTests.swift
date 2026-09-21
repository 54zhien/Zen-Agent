import Foundation
import Testing

@testable import ZenAgent

private func i07ToolResults(
    in request: ProviderChatRequest
) -> [(toolCallID: String, content: String)] {
    request.messages.compactMap { message in
        guard case .toolResult(let toolCallID, let content) = message else {
            return nil
        }
        return (toolCallID, content)
    }
}

private actor I07CancellationRaceOwner {
    private var transitionError: String?

    func cancel(runID: String, store: PersistenceStore) {
        do {
            try store.transitionRun(
                id: runID,
                expectedState: .stopping,
                to: .cancelled,
                endReason: .cancelledByUser
            )
        } catch {
            transitionError = String(describing: error)
        }
    }

    func error() -> String? { transitionError }
}

@Suite("Multi-tool batch continuation")
struct MultiToolBatchTests {
    @Test("all calls in one provider response settle before continuation")
    func waitsForTheWholeBatch() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let ledger = I07ProviderLedger()
        let toolLedger = I07ToolLedger()
        let provider = I07ScriptedProvider(
            ledger: ledger,
            instanceID: fixture.instance.id,
            scripts: [
                [
                    .toolCall(.init(
                        id: "provider-call-0",
                        index: 0,
                        name: "echo",
                        argumentsJSON: #"{"value":0}"#
                    )),
                    .toolCall(.init(
                        id: "provider-call-1",
                        index: 1,
                        name: "echo",
                        argumentsJSON: #"{"value":1}"#
                    )),
                    .finish(.toolCalls),
                ],
                [
                    .textDelta("batch complete"),
                    .finish(.stop),
                ],
            ],
            toolLedger: toolLedger,
            store: fixture.store,
            conversationID: I05RuntimeTestFixtures.conversationID
        )
        let toolRegistry = try ToolRegistry(tools: [
            I07RecordingTool(
                id: "echo",
                approvalRequirement: .notRequired,
                ledger: toolLedger
            ),
            I07RecordingTool(
                id: "approval-required",
                approvalRequirement: .required,
                ledger: toolLedger
            ),
        ])
        let runtime = ConversationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials,
            toolRegistry: toolRegistry
        )

        let runID = try await runtime.send(I05RuntimeTestFixtures.command())
        let run = try fixture.store.run(id: runID)
        let assistantMessages = try fixture.store.messages(
            inConversation: I05RuntimeTestFixtures.conversationID
        ).filter { $0.role == .assistant }
        let requests = await ledger.requestsSnapshot()
        #expect(requests.count == 2)
        guard requests.count > 1 else {
            #expect(false, "the second provider request must exist")
            return
        }
        let invocations = await toolLedger.snapshot()
        let invocationsAtContinuation = await ledger.toolInvocations(atRequest: 1)
        let durableResultsAtContinuation = await ledger.durableResults(atRequest: 1)

        #expect(run?.state == .completed)
        #expect(assistantMessages.count == 1)

        guard let responseID = run?.responseMessageID else {
            #expect(false, "the completed run must point to its assistant response")
            return
        }
        guard let assistant = assistantMessages.first else {
            #expect(false, "the batch continuation must materialize an assistant response")
            return
        }
        #expect(responseID == assistant.id)

        let parts = try fixture.store.parts(ofMessage: assistant.id)
        let text = try parts
            .filter { $0.kind == .text }
            .compactMap { try fixture.store.text(ofPart: $0.id) }
            .joined()
        #expect(text == "batch complete")

        let calls = try fixture.store.toolCalls(inRun: runID).sorted {
            ($0.batchSequence ?? -1) < ($1.batchSequence ?? -1)
        }
        #expect(calls.count == 2)
        #expect(calls.map { $0.providerCallID ?? "" } == [
            "provider-call-0",
            "provider-call-1",
        ])
        #expect(calls.map { $0.batchSequence ?? -1 } == [0, 1])
        let batchIDs = calls.compactMap(\.batchID)
        #expect(batchIDs.count == 2)
        #expect(batchIDs.first?.isEmpty == false)
        #expect(Set(batchIDs).count == 1)
        #expect(calls.map(\.state) == [.succeeded, .succeeded])

        let expectedResults = [
            #"echo executed: {"value":0}"#,
            #"echo executed: {"value":1}"#,
        ]
        #expect(durableResultsAtContinuation.count == 2)
        #expect(
            Set(durableResultsAtContinuation.map(\.toolCallID)) == Set(calls.map(\.id))
        )
        #expect(
            Set(durableResultsAtContinuation.map(\.payload)) == Set(expectedResults)
        )
        for (call, expectedResult) in zip(calls, expectedResults) {
            guard let result = try fixture.store.toolResult(toolCallID: call.id) else {
                #expect(false, "each call in a completed batch must have a ToolResult")
                return
            }
            #expect(result.toolCallID == call.id)
            #expect(result.payload == expectedResult)
        }

        #expect(invocations.count == 2)
        #expect(invocations.map(\.toolID) == ["echo", "echo"])
        #expect(invocations.map(\.argumentsJSON) == [
            #"{"value":0}"#,
            #"{"value":1}"#,
        ])
        #expect(invocations.map(\.dispatchCount) == [1, 1])
        #expect(invocations.map(\.idempotencyKey) == calls.map(\.id))
        #expect(invocations.map(\.outcome) == ["succeeded", "succeeded"])

        #expect(invocationsAtContinuation.count == 2)
        #expect(invocationsAtContinuation.map(\.idempotencyKey) ==
            invocations.map(\.idempotencyKey))
        #expect(invocationsAtContinuation.map(\.outcome) == [
            "succeeded",
            "succeeded",
        ])

        let continuationResults = i07ToolResults(in: requests[1])
        #expect(continuationResults.count == 2)
        #expect(continuationResults.map { $0.toolCallID } == [
            "provider-call-0",
            "provider-call-1",
        ])
        #expect(continuationResults.map { $0.content } == expectedResults)

        let callParts = parts.filter { $0.kind == .toolCall }
        let resultParts = parts.filter { $0.kind == .toolResult }
        #expect(callParts.count == 2)
        #expect(resultParts.count == 2)
        let callPartPayloads = try callParts.map {
            try JSONDecoder().decode(
                ToolCallPartPayload.self,
                from: Data($0.payload.utf8)
            )
        }
        let resultPartPayloads = try resultParts.map {
            try JSONDecoder().decode(
                ToolResultPartPayload.self,
                from: Data($0.payload.utf8)
            )
        }
        #expect(callPartPayloads.map(\.toolCallID) == calls.map(\.id))
        #expect(resultPartPayloads.map(\.toolCallID) == calls.map(\.id))
    }

    @Test("mid-batch Stop settles dispatched and undispatched calls without continuation")
    func stopDuringToolBatchDoesNotContinue() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let ledger = I07ProviderLedger()
        let toolLedger = I07ToolLedger()
        let provider = I07ScriptedProvider(
            ledger: ledger,
            instanceID: fixture.instance.id,
            scripts: [
                [
                    .toolCall(.init(
                        id: "provider-call-stop-0",
                        index: 0,
                        name: "echo",
                        argumentsJSON: #"{"value":"first"}"#
                    )),
                    .toolCall(.init(
                        id: "provider-call-stop-1",
                        index: 1,
                        name: "echo",
                        argumentsJSON: #"{"value":"second"}"#
                    )),
                    .finish(.toolCalls),
                ],
                [
                    .textDelta("must not be requested"),
                    .finish(.stop),
                ],
            ],
            toolLedger: toolLedger,
            store: fixture.store,
            conversationID: I05RuntimeTestFixtures.conversationID
        )
        let toolRegistry = try ToolRegistry(tools: [
            I07RecordingTool(
                id: "echo",
                approvalRequirement: .notRequired,
                ledger: toolLedger,
                executionMode: .waitForCancellation
            ),
            I07RecordingTool(
                id: "approval-required",
                approvalRequirement: .required,
                ledger: toolLedger
            ),
        ])
        let runtime = ConversationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials,
            toolRegistry: toolRegistry
        )

        let runID = try await runtime.start(I05RuntimeTestFixtures.command())
        await toolLedger.waitForDispatchCount(1)
        try await runtime.stop(runID: runID)
        try await runtime.waitForCompletion(runID: runID)

        let run = try fixture.store.run(id: runID)
        let requests = await ledger.requestsSnapshot()
        let invocations = await toolLedger.snapshot()
        let calls = try fixture.store.toolCalls(inRun: runID).sorted {
            ($0.batchSequence ?? -1) < ($1.batchSequence ?? -1)
        }

        #expect(run?.state == .cancelled)
        #expect(run?.endReason == .cancelledByUser)
        #expect(requests.count == 1)
        #expect(calls.count == 2)
        guard calls.count == 2 else {
            #expect(false, "Stop must settle every call in the provider batch")
            return
        }
        #expect(calls.map { $0.providerCallID ?? "" } == [
            "provider-call-stop-0",
            "provider-call-stop-1",
        ])
        #expect(calls.map { $0.batchSequence ?? -1 } == [0, 1])
        let batchIDs = calls.compactMap(\.batchID)
        #expect(batchIDs.count == 2)
        #expect(batchIDs.first?.isEmpty == false)
        #expect(Set(batchIDs).count == 1)
        #expect(calls.map(\.state) == [.indeterminate, .notExecuted])
        #expect(try fixture.store.toolResult(toolCallID: calls[0].id) == nil)
        #expect(try fixture.store.toolResult(toolCallID: calls[1].id) == nil)

        #expect(invocations.count == 1)
        guard let invocation = invocations.first else {
            #expect(false, "the first call must have reached the executor")
            return
        }
        #expect(invocation.toolID == "echo")
        #expect(invocation.argumentsJSON == #"{"value":"first"}"#)
        #expect(invocation.dispatchCount == 1)
        #expect(invocation.idempotencyKey == calls[0].id)
        #expect(invocation.outcome == "dispatched")
    }

    @Test("a settlement write failure cannot produce a clean cancellation")
    func settlementWriteFailureDoesNotFakeCancellation() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let ledger = I07ProviderLedger()
        let toolLedger = I07ToolLedger()
        let provider = I07ScriptedProvider(
            ledger: ledger,
            instanceID: fixture.instance.id,
            scripts: [
                [
                    .toolCall(.init(
                        id: "provider-call-failing-settlement-0",
                        index: 0,
                        name: "echo",
                        argumentsJSON: #"{"value":"first"}"#
                    )),
                    .toolCall(.init(
                        id: "provider-call-failing-settlement-1",
                        index: 1,
                        name: "echo",
                        argumentsJSON: #"{"value":"second"}"#
                    )),
                    .finish(.toolCalls),
                ],
                [
                    .textDelta("must not be requested"),
                    .finish(.stop),
                ],
            ],
            toolLedger: toolLedger,
            store: fixture.store,
            conversationID: I05RuntimeTestFixtures.conversationID
        )
        let toolRegistry = try ToolRegistry(tools: [
            I07RecordingTool(
                id: "echo",
                approvalRequirement: .notRequired,
                ledger: toolLedger,
                executionMode: .waitForCancellation
            ),
        ])

        // This is a real SQLite write failure: the trigger aborts the UPDATE that
        // would record `.indeterminate`, while leaving the already-dispatched row
        // durable as `.dispatched` for the assertions below.
        try fixture.store.database.write { db in
            try db.execute(
                sql: """
                    CREATE TRIGGER i07_fail_indeterminate_settlement
                    BEFORE UPDATE OF state ON toolCall
                    WHEN NEW.state = 'indeterminate'
                    BEGIN
                        SELECT RAISE(ABORT, 'I07 injected settlement write failure');
                    END
                    """
            )
        }

        let runtime = ConversationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials,
            toolRegistry: toolRegistry
        )

        let runID = try await runtime.start(I05RuntimeTestFixtures.command())
        await toolLedger.waitForDispatchCount(1)
        try await runtime.stop(runID: runID)
        var completionError: Error?
        do {
            try await runtime.waitForCompletion(runID: runID)
        } catch {
            completionError = error
        }

        let run = try fixture.store.run(id: runID)
        let calls = try fixture.store.toolCalls(inRun: runID).sorted {
            ($0.batchSequence ?? -1) < ($1.batchSequence ?? -1)
        }
        let requests = await ledger.requestsSnapshot()

        #expect(run?.state == .failed)
        #expect(run?.endReason == .toolOutcomeUnknown)
        guard let completionError,
              let diagnostic = completionError as? ConversationProjectionError
        else {
            #expect(false, "the caller must observe the settlement failure")
            return
        }
        guard case .other(let reason) = diagnostic else {
            #expect(false, "the settlement failure must not be dropped or reclassified")
            return
        }
        #expect(reason.contains("cancellationSettlementFailed"))
        #expect(requests.count == 1)
        #expect(calls.count == 2)
        guard calls.count == 2 else {
            #expect(false, "the failure injection must still leave both batch calls inspectable")
            return
        }
        #expect(calls[0].state == .dispatched)
        #expect(calls[1].state == .notExecuted)

        let hasUnsettledCall = calls.contains { call in
            switch call.state {
            case .validated,
                 .waitingForApproval,
                 .waitingForSystemPermissionConsent,
                 .approved,
                 .prepared,
                 .dispatched:
                return true
            case .succeeded,
                 .failed,
                 .rejected,
                 .cancelled,
                 .notExecuted,
                 .indeterminate:
                return false
            }
        }
        #expect(
            !(run?.state == .cancelled && hasUnsettledCall),
            "a cancelled Run must not coexist with a ToolCall that still needs settlement"
        )
    }

    @Test("a notExecuted insert failure cannot produce a clean cancellation")
    func notExecutedInsertFailureDoesNotFakeCancellation() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let ledger = I07ProviderLedger()
        let toolLedger = I07ToolLedger()
        let provider = I07ScriptedProvider(
            ledger: ledger,
            instanceID: fixture.instance.id,
            scripts: [
                [
                    .toolCall(.init(
                        id: "provider-call-failing-insert-0",
                        index: 0,
                        name: "echo",
                        argumentsJSON: #"{"value":"first"}"#
                    )),
                    .toolCall(.init(
                        id: "provider-call-failing-insert-1",
                        index: 1,
                        name: "echo",
                        argumentsJSON: #"{"value":"second"}"#
                    )),
                    .finish(.toolCalls),
                ],
                [
                    .textDelta("must not be requested"),
                    .finish(.stop),
                ],
            ],
            toolLedger: toolLedger,
            store: fixture.store,
            conversationID: I05RuntimeTestFixtures.conversationID
        )
        let toolRegistry = try ToolRegistry(tools: [
            I07RecordingTool(
                id: "echo",
                approvalRequirement: .notRequired,
                ledger: toolLedger,
                executionMode: .waitForCancellation
            ),
        ])

        // The second call has not reached ToolRuntime.complete when Stop wins the
        // serial batch. Abort only the compensating INSERT, leaving no durable row
        // for that provider call and exercising the report-with-no-flags path.
        try fixture.store.database.write { db in
            try db.execute(
                sql: """
                    CREATE TRIGGER i07_fail_not_executed_insert
                    BEFORE INSERT ON toolCall
                    WHEN NEW.state = 'notExecuted'
                        AND NEW.providerCallID = 'provider-call-failing-insert-1'
                    BEGIN
                        SELECT RAISE(ABORT, 'I07 injected notExecuted insert failure');
                    END
                    """
            )
        }

        let runtime = ConversationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials,
            toolRegistry: toolRegistry
        )

        let runID = try await runtime.start(I05RuntimeTestFixtures.command())
        await toolLedger.waitForDispatchCount(1)
        try await runtime.stop(runID: runID)
        var completionError: Error?
        do {
            try await runtime.waitForCompletion(runID: runID)
        } catch {
            completionError = error
        }

        let run = try fixture.store.run(id: runID)
        let calls = try fixture.store.toolCalls(inRun: runID).sorted {
            ($0.batchSequence ?? -1) < ($1.batchSequence ?? -1)
        }
        let requests = await ledger.requestsSnapshot()

        #expect(run?.state == .failed)
        #expect(run?.endReason == .toolFailed)
        #expect(run?.state != .cancelled)
        #expect(run?.endReason != .cancelledByUser)
        guard let completionError,
              let diagnostic = completionError as? ConversationProjectionError
        else {
            #expect(false, "the caller must observe the settlement failure")
            return
        }
        guard case .other(let reason) = diagnostic else {
            #expect(false, "the settlement failure must not be dropped or reclassified")
            return
        }
        #expect(reason.contains("cancellationSettlementFailed"))
        #expect(requests.count == 1)
        #expect(calls.count == 1)
        guard let call = calls.first else {
            #expect(false, "the already-dispatched call must remain inspectable")
            return
        }
        #expect(call.providerCallID == "provider-call-failing-insert-0")
        #expect(call.state == .indeterminate)
        #expect(
            try fixture.store.toolCalls(inRun: runID).first(where: {
                $0.providerCallID == "provider-call-failing-insert-1"
            }) == nil,
            "the injected INSERT must leave the notExecuted row absent"
        )
    }

    @Test("a settlement failure after concurrent cancellation remains observable")
    func settlementFailureAfterConcurrentCancellationIsNotDropped() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let ledger = I07ProviderLedger()
        let toolLedger = I07ToolLedger()
        let raceOwner = I07CancellationRaceOwner()
        let provider = I07ScriptedProvider(
            ledger: ledger,
            instanceID: fixture.instance.id,
            scripts: [
                [
                    .toolCall(.init(
                        id: "provider-call-cancelled-race",
                        index: 0,
                        name: "echo",
                        argumentsJSON: #"{"value":"race"}"#
                    )),
                    .finish(.toolCalls),
                ],
                [
                    .textDelta("must not be requested"),
                    .finish(.stop),
                ],
            ],
            toolLedger: toolLedger,
            store: fixture.store,
            conversationID: I05RuntimeTestFixtures.conversationID
        )
        let toolRegistry = try ToolRegistry(tools: [
            I07RecordingTool(
                id: "echo",
                approvalRequirement: .notRequired,
                ledger: toolLedger,
                executionMode: .waitForCancellation
            ),
        ])

        try fixture.store.database.write { db in
            try db.execute(
                sql: """
                    CREATE TRIGGER i07_fail_raced_indeterminate_settlement
                    BEFORE UPDATE OF state ON toolCall
                    WHEN NEW.state = 'indeterminate'
                        AND OLD.state = 'dispatched'
                    BEGIN
                        SELECT RAISE(ABORT, 'I07 injected raced settlement write failure');
                    END
                    """
            )
        }

        let runtime = ConversationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials,
            onEvent: { event in
                guard case .runStateChanged(let runID, .stopping) = event else {
                    return
                }
                await raceOwner.cancel(runID: runID, store: fixture.store)
            },
            toolRegistry: toolRegistry
        )

        let runID = try await runtime.start(I05RuntimeTestFixtures.command())
        await toolLedger.waitForDispatchCount(1)
        try await runtime.stop(runID: runID)

        var observedError: Error?
        do {
            try await runtime.waitForCompletion(runID: runID)
        } catch {
            observedError = error
        }

        #expect(await raceOwner.error() == nil)
        guard let observedError else {
            #expect(false, "a cancelled Run with an unsettled dispatched call must not look successful")
            return
        }
        guard let diagnostic = observedError as? ConversationProjectionError else {
            #expect(false, "settlement failure must reach waitForCompletion as a diagnostic")
            return
        }
        guard case .other(let reason) = diagnostic else {
            #expect(false, "settlement failure must not be replaced by a projection category")
            return
        }
        #expect(reason.contains("cancellationSettlementFailed"))

        let run = try fixture.store.run(id: runID)
        let calls = try fixture.store.toolCalls(inRun: runID)
        let requests = await ledger.requestsSnapshot()
        #expect(run?.state == .cancelled)
        #expect(calls.count == 1)
        #expect(calls.first?.state == .dispatched)
        #expect(requests.count == 1)
    }
}

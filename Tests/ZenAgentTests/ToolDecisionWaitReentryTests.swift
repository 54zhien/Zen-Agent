import Foundation
import Testing

@testable import ZenAgent

/// The approval gate is the one place where a serial tool batch parks itself and waits
/// for the outside world to answer. Both probes below record their decision while the
/// batch is still settling into that wait — the ToolCall is durable before the gate is
/// announced, and the gate is announced before the batch waits — which is the only
/// stretch where a decision and the waiter that is supposed to receive it can cross.
///
/// A crossing that goes the wrong way does not fail loudly: the batch simply waits for a
/// decision that already happened. So the runtime is given a bound here, and a stall is
/// reported as a failed expectation instead of as a suite that never finishes.
@Suite("Tool decision wait reentry")
struct ToolDecisionWaitReentryTests {

    private static let watchdog: Duration = .seconds(10)

    /// Bounds a probe end to end. The runtime exposes no "am I waiting?" surface — the
    /// observable form of a lost wake-up is silence — so the bound is what turns that
    /// silence into a result the test can assert on.
    private func bounded(_ body: @escaping @Sendable () async -> String) async -> String {
        await withTaskGroup(of: String.self) { group in
            group.addTask { await body() }
            group.addTask {
                try? await Task.sleep(for: Self.watchdog)
                return "stalled: the run did not settle within \(Self.watchdog)"
            }
            let first = await group.next() ?? "no outcome"
            group.cancelAll()
            return first
        }
    }

    private struct ApprovalProbe: Sendable {
        let store: PersistenceStore
        let ledger: I07ProviderLedger
        let toolLedger: I07ToolLedger
        let eventLedger: I07EventLedger
        let runtime: ConversationRuntime
    }

    /// One tool call that requires approval, followed by a continuation response. The
    /// second script is what proves the batch was released rather than merely settled.
    private func makeProbe() throws -> ApprovalProbe {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let ledger = I07ProviderLedger()
        let toolLedger = I07ToolLedger()
        let eventLedger = I07EventLedger()
        let provider = I07ScriptedProvider(
            ledger: ledger,
            instanceID: fixture.instance.id,
            scripts: [
                [
                    .toolCall(.init(
                        id: "provider-call-approval",
                        index: 0,
                        name: "approval-required",
                        argumentsJSON: #"{"value":"approved"}"#
                    )),
                    .finish(.toolCalls),
                ],
                [
                    .textDelta("continued after approval"),
                    .finish(.stop),
                ],
            ],
            toolLedger: toolLedger,
            store: fixture.store,
            conversationID: I05RuntimeTestFixtures.conversationID
        )
        let toolRegistry = try ToolRegistry(tools: [
            I07RecordingTool(
                id: "approval-required",
                approvalRequirement: .required,
                ledger: toolLedger
            ),
        ])
        return ApprovalProbe(
            store: fixture.store,
            ledger: ledger,
            toolLedger: toolLedger,
            eventLedger: eventLedger,
            runtime: ConversationRuntime(
                store: fixture.store,
                provider: provider,
                credentials: fixture.credentials,
                onEvent: { event in await eventLedger.append(event) },
                toolRegistry: toolRegistry
            )
        )
    }

    /// The settlement an approved gate owes its run: the same ToolCall the gate named,
    /// executed exactly once, and a continuation request that carries its result. None
    /// of this may be reached by creating a replacement call.
    private func expectSettledApproval(
        _ probe: ApprovalProbe,
        runID: String,
        toolCallID: String
    ) async throws {
        let run = try probe.store.run(id: runID)
        #expect(run?.state == .completed)

        let calls = try probe.store.toolCalls(inRun: runID)
        #expect(calls.count == 1)
        guard let call = calls.first else {
            #expect(false, "the approval must keep the ToolCall the gate announced")
            return
        }
        #expect(call.id == toolCallID)
        #expect(call.providerCallID == "provider-call-approval")
        #expect(call.state == .succeeded)

        let invocations = await probe.toolLedger.snapshot()
        #expect(invocations.count == 1)
        #expect(invocations.first?.toolID == "approval-required")
        #expect(invocations.first?.idempotencyKey == toolCallID)
        #expect(invocations.first?.dispatchCount == 1)
        #expect(invocations.first?.outcome == "succeeded")

        let requests = await probe.ledger.requestsSnapshot()
        #expect(requests.count == 2)
        guard requests.count > 1 else { return }

        let results = requests[1].messages.compactMap {
            message -> (toolCallID: String, content: String)? in
            guard case .toolResult(let toolCallID, let content) = message else {
                return nil
            }
            return (toolCallID, content)
        }
        #expect(results.count == 1)
        #expect(results.first?.toolCallID == "provider-call-approval")
        #expect(results.first?.content == #"approval-required executed: {"value":"approved"}"#)
    }

    @Test("approving the moment the gate is announced still continues the batch")
    func approvalRacingTheWaitContinuesTheBatch() async throws {
        let probe = try makeProbe()
        let runID = try await probe.runtime.start(I05RuntimeTestFixtures.command())

        // Resumes as soon as the announcement is observed, so the approval is issued
        // while the batch is still on its way into the wait.
        let approvalID = await probe.eventLedger.waitForApproval()

        let outcome = await bounded {
            do {
                try await probe.runtime.approve(toolCallID: approvalID)
                try await probe.runtime.waitForCompletion(runID: runID)
                return "ok"
            } catch {
                return "threw: \(error)"
            }
        }

        #expect(outcome == "ok", "\(outcome)")
        try await expectSettledApproval(probe, runID: runID, toolCallID: approvalID)
    }

    @Test("a decision recorded before the batch waits is not waited on")
    func decisionRecordedBeforeTheWaitIsNotWaitedOn() async throws {
        let probe = try makeProbe()
        let runID = try await probe.runtime.start(I05RuntimeTestFixtures.command())

        // The announcement follows the durable ToolCall, so waiting for the row instead
        // of for the event is what puts this decision on the early side of the wait: the
        // batch is handed a call whose answer already exists by the time it looks.
        var approvalID: String?
        for _ in 0..<1_000 where approvalID == nil {
            approvalID = try probe.store.toolCalls(inRun: runID).first?.id
            if approvalID == nil {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        guard let approvalID else {
            #expect(false, "the gate must create a durable ToolCall")
            return
        }

        let outcome = await bounded {
            do {
                try await probe.runtime.approve(toolCallID: approvalID)
                try await probe.runtime.waitForCompletion(runID: runID)
                return "ok"
            } catch {
                return "threw: \(error)"
            }
        }

        #expect(outcome == "ok", "\(outcome)")
        try await expectSettledApproval(probe, runID: runID, toolCallID: approvalID)
    }
}

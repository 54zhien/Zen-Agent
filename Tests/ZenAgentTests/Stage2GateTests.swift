import Foundation
import Testing

@testable import ZenAgent

/// The Stage 2 closure gate.
///
/// This is not a new production contract. It is the integration acceptance for the
/// contracts the increments I01–I08 already proved one at a time: the four gates below
/// drive the *real* runtime — `ConversationRuntime`, `AgentRuntime`, `ToolRuntime`,
/// `RunRecovery` — against a real file-backed database, and then read the database
/// rather than the runtime's memory for the verdict.
///
/// Nothing here may reach the network, a live endpoint, a real API key, the Keychain,
/// an MCP server or a system permission prompt. The provider is scripted, the
/// credential backend is in memory, and the store is a temporary file.
///
/// Each `@Test` body is deliberately thin: it owns the scratch path and hands it to an
/// `assertGate…` method that owns the stores. That split is a lifetime rule, not style.
/// A store still alive when `Fixtures.cleanUp` deletes the directory is a database
/// deleted out from under an open connection — which is what makes libsqlite3 log its
/// `BUG IN CLIENT` line about the WAL files it just lost.
@Suite("Stage 2 closure gate")
struct Stage2GateTests {

    private static let question = "What is 6*7?"
    private static let providerCallID = "provider-call-1"
    private static let finalAnswer = "The result is 42."

    /// The tool result the model is handed for `6*7`.
    ///
    /// `CalculatorTool` renders its `Double` through `String(value)`, and
    /// `ToolRegistryTests` already pins that spelling ("1 + 2 * 3" -> "7.0"). The gate
    /// asserts the contract that exists: "42.0", not a rounded "42".
    private static let toolResultPayload = "42.0"

    private static let sideEffectCallID = "provider-call-side-effect"
    private static let sideEffectToolID = "stage2_side_effect"

    // MARK: - Gate A

    @Test("user model tool model closes one parent run")
    func userModelToolModelClosesOneParentRun() async throws {
        let url = try Fixtures.scratchPath(name: "stage2-gate-a.sqlite")
        defer { Fixtures.cleanUp(url) }
        try await assertGateA(at: url)
    }

    private func assertGateA(at url: URL) async throws {
        let components = try Stage2GateFixture.makeDiskComponents(at: url)
        let ledger = Stage2ProviderLedger()
        let runID = try await runCalculatorLoop(components: components, ledger: ledger)

        let requests = await ledger.requestsSnapshot()
        #expect(requests.count == 2, "one tool round trip is exactly two provider requests")
        guard requests.count == 2 else { return }

        // Request #1: the user turn, and the calculator's schema as the only tool surface.
        #expect(requests[0].modelID == Stage2GateFixture.modelID)
        #expect(requests[0].messages == [.user(Self.question)])
        #expect(requests[0].tools.map(\.name) == [CalculatorTool.toolID])
        #expect(
            requests[0].tools.first?.parameters == CalculatorTool().descriptor.inputSchema,
            "the model must be offered the production calculator schema, not a paraphrase"
        )

        // Request #2: the continuation carries the *same* provider tool call and the
        // durable result, still addressed by the provider's own call id.
        #expect(requests[1].messages.count == 3, "user, assistant tool call, tool result")
        guard requests[1].messages.count == 3,
              case .assistant(let assistantText, _, let toolCalls) = requests[1].messages[1],
              case .toolResult(let toolCallID, let resultContent) = requests[1].messages[2]
        else {
            Issue.record("the second provider request must be a tool continuation")
            return
        }
        #expect(assistantText == nil, "the tool-call step produced no visible text")
        #expect(toolCalls.count == 1)
        #expect(toolCalls.first?.id == Self.providerCallID)
        #expect(toolCalls.first?.name == CalculatorTool.toolID)
        #expect(toolCalls.first?.argumentsJSON == #"{"expression":"6*7"}"#)
        #expect(toolCallID == Self.providerCallID)
        #expect(resultContent == Self.toolResultPayload)

        try assertClosedParentRun(in: components.store, runID: runID)
    }

    // MARK: - Gate B

    @Test("stop cancels the run without accepting late provider output")
    func stopCancelsWithoutAcceptingLateOutput() async throws {
        let url = try Fixtures.scratchPath(name: "stage2-gate-b.sqlite")
        defer { Fixtures.cleanUp(url) }
        try await assertGateB(at: url)
    }

    private func assertGateB(at url: URL) async throws {
        let components = try Stage2GateFixture.makeDiskComponents(at: url)
        let box = Stage2StreamBox()
        let ledger = Stage2ProviderLedger()
        let provider = Stage2ScriptedProvider(
            ledger: ledger,
            scripts: [
                .holding(prefix: [.textDelta("partial")], box: box),
                // The run after the cancellation has to be able to finish, so the
                // provider stops holding after the request it was holding for.
                .events([.textDelta("second answer"), .finish(.stop)]),
            ]
        )
        let recorder = Stage2GateEventRecorder()
        let runtime = ConversationRuntime(
            store: components.store,
            provider: provider,
            credentials: components.credentials,
            onEvent: { event in await recorder.append(event) },
            toolRegistry: try ToolRegistry(tools: [])
        )
        await recorder.parkOnState(.stopping)

        let sendTask = Task {
            try await runtime.send(Stage2GateFixture.command(text: "stop me"))
        }
        await box.waitUntilReady()
        let runID = await recorder.waitForState(.streaming)
        let partID = await recorder.waitForPartStarted(runID: runID)

        // The provider's first output is durable before Stop is asked for.
        //
        // The durable acknowledgement is the started part, not the text: the runtime
        // coalesces text in a streaming accumulator whose threshold is deliberately
        // private policy, and flushes it at the cancellation boundary. That boundary is
        // exactly what the assertion after Stop checks.
        #expect(try components.store.part(id: partID)?.state == .streaming)

        let stopTask = Task { try await runtime.stop(runID: runID) }
        await recorder.waitForState(.stopping)
        await recorder.waitUntilParked()

        // Late output inside the stopping window. Nothing may commit it.
        box.yieldLate(.textDelta("SHOULD_NOT_APPEAR"))

        // The runtime is parked inside its own projection of `stopping`, so this Send
        // provably lands while `stopping` is durable and the terminal transition has not
        // begun. Asking from the test body without the park would instead be a race
        // against cancellation settling.
        let messagesBeforeRejectedSend = try components.store.messages(
            inConversation: Stage2GateFixture.conversationID
        )

        var secondSendFailure: Error?
        do {
            _ = try await runtime.send(Stage2GateFixture.command(text: "second send"))
        } catch {
            secondSendFailure = error
        }

        #expect(
            secondSendFailure as? PersistenceError == .conversationAlreadyHasActiveRun(
                conversationID: Stage2GateFixture.conversationID
            ),
            "stopping still owns the conversation's active slot"
        )

        let messagesAfterRejectedSend = try components.store.messages(
            inConversation: Stage2GateFixture.conversationID
        )

        #expect(
            Set(messagesAfterRejectedSend.map(\.id)) == Set(messagesBeforeRejectedSend.map(\.id)),
            "a rejected send must not leave its user message behind"
        )

        await recorder.releasePark()
        try await stopTask.value
        _ = try await sendTask.value
        await box.waitUntilCancelled()

        let storedRun = try components.store.run(id: runID)
        let run = try #require(storedRun)
        #expect(run.state == .cancelled)
        #expect(run.endReason == .cancelledByUser)
        #expect(run.activeSlot == nil, "the cancelled transition releases the slot")
        #expect(box.cancellations > 0, "Stop must actually tear the provider stream down")

        let responseID = try #require(run.responseMessageID)
        let parts = try components.store.parts(ofMessage: responseID)
        #expect(parts.count == 1)
        let part = try #require(parts.first)
        #expect(part.id == partID)
        #expect(part.state == .cancelled)
        #expect(
            try components.store.text(ofPart: part.id) == "partial",
            "the partial the provider produced before Stop must survive"
        )
        #expect(
            !(try components.store.text(ofPart: part.id)?.contains("SHOULD_NOT_APPEAR") ?? false),
            "output produced after Stop must never reach the partial"
        )
        #expect(
            parts.allSatisfy { $0.state != .streaming && $0.state != .pending },
            "cancellation must settle every open part"
        )
        #expect(
            try components.store.activeParentRuns(
                inConversation: Stage2GateFixture.conversationID
            ).isEmpty
        )

        // Terminal means free: the conversation accepts a new send rather than rejecting
        // it, and that send runs to completion.
        let secondRunID = try await runtime.send(
            Stage2GateFixture.command(text: "after cancellation")
        )
        #expect(secondRunID != runID, "a new send is a new Parent Run")
        let storedSecondRun = try components.store.run(id: secondRunID)
        let secondRun = try #require(storedSecondRun)
        #expect(secondRun.state == .completed)
        #expect(secondRun.endReason == .completed)
        #expect(
            try components.store.activeParentRuns(
                inConversation: Stage2GateFixture.conversationID
            ).isEmpty
        )
        let requests = await ledger.requestsSnapshot()
        #expect(requests.count == 2, "one request per run")
        guard requests.count == 2 else { return }
        #expect(requests[1].messages == [.user("after cancellation")])
    }

    // MARK: - Gate C

    @Test("recovery never repeats a dispatched side effect")
    func recoveryNeverRepeatsADispatchedSideEffect() async throws {
        let url = try Fixtures.scratchPath(name: "stage2-gate-c.sqlite")
        defer { Fixtures.cleanUp(url) }
        try await assertGateC(at: url)
    }

    private func assertGateC(at url: URL) async throws {
        let components = try Stage2GateFixture.makeDiskComponents(at: url)
        let ledger = SideEffectLedger()
        let gate = Stage2DispatchGate()
        let providerLedger = Stage2ProviderLedger()
        let registry = try ToolRegistry(tools: [
            Stage2SideEffectTool(ledger: ledger, gate: gate),
        ])
        let provider = Stage2ScriptedProvider(
            ledger: providerLedger,
            scripts: [
                .events([
                    .toolCall(ProviderToolCall(
                        id: Self.sideEffectCallID,
                        index: 0,
                        name: Self.sideEffectToolID,
                        argumentsJSON: "{}"
                    )),
                    .finish(.toolCalls),
                ]),
            ]
        )
        let recorder = Stage2GateEventRecorder()

        // Runtime A. It stays alive for the whole gate: the point is that a second
        // runtime recovers the database while the first one is still inside the dispatch
        // window, not that the first one was cleaned up.
        let runtimeA = ConversationRuntime(
            store: components.store,
            provider: provider,
            credentials: components.credentials,
            onEvent: { event in await recorder.append(event) },
            toolRegistry: registry
        )
        let runID = try await runtimeA.start(
            Stage2GateFixture.command(text: "write something")
        )

        // The shared tool is an external write, so the real path reaches dispatch only
        // through the approval the provider's call requires.
        let callID = await recorder.waitForApproval()
        try await runtimeA.approve(toolCallID: callID)
        await gate.waitUntilDispatched()

        // Durable state at the crash point, read through a second connection so the
        // answer is the database's and not the live runtime's memory.
        let witness = try Stage2GateFixture.reopen(url)
        let storedCall = try witness.toolCall(id: callID)
        let call = try #require(storedCall)
        #expect(call.state == .dispatched, "the marker commits before the executor is entered")
        #expect(try witness.toolResult(toolCallID: callID) == nil)
        #expect(try witness.run(id: runID)?.state == .executingTools)

        let atCrash = await ledger.snapshot()
        #expect(atCrash.count == 1, "the external write has happened exactly once")
        #expect(atCrash.first?.dispatchCount == 1)
        #expect(
            atCrash.first?.toolCallID == callID,
            "the executor is handed the durable ToolCall identity as its target"
        )
        #expect(
            atCrash.first?.idempotencyKey == callID,
            "the idempotency key is the ToolCall id"
        )

        // A new process: a new store, a new ToolRuntime, the same file. The executor is
        // *available* here — that is what makes "recovery did not call it" a claim about
        // recovery rather than about a missing dependency.
        let reopened = try Stage2GateFixture.reopen(url)
        let runtimeB = ToolRuntime(store: reopened, registry: registry)
        try await RunRecovery(store: reopened, toolRuntime: runtimeB).recover(runID: runID)

        let afterRecovery = await ledger.snapshot()
        #expect(
            afterRecovery.count == 1,
            "recovery must not call the executor for a dispatched ToolCall"
        )
        #expect(try reopened.toolCall(id: callID)?.state == .indeterminate)
        #expect(try reopened.run(id: runID)?.state == .failed)
        #expect(try reopened.run(id: runID)?.endReason == .toolOutcomeUnknown)
        #expect(try reopened.toolResult(toolCallID: callID) == nil)

        // Release A. Its late completion has to lose the compare-and-swap: the durable
        // row is no longer `dispatched`, so a `succeeded` write cannot land.
        gate.release()
        try await runtimeA.waitForCompletion(runID: runID)

        let afterLateCompletion = await ledger.snapshot()
        #expect(afterLateCompletion.count == 1)
        #expect(
            afterLateCompletion.first?.dispatchCount == 1,
            "the late completion must not produce a second external write"
        )
        let storedSettled = try reopened.toolCall(id: callID)
        let settled = try #require(storedSettled)
        #expect(settled.state == .indeterminate, "a late success must not overwrite the verdict")
        #expect(try reopened.toolResult(toolCallID: callID) == nil, "no result may be written late")
        #expect(try reopened.run(id: runID)?.state == .failed)
        #expect(try reopened.run(id: runID)?.endReason == .toolOutcomeUnknown)
    }

    // MARK: - Gate D

    @Test("a completed run is fully recoverable after the database is reopened")
    func completedRunIsRecoverableAfterReopen() async throws {
        let url = try Fixtures.scratchPath(name: "stage2-gate-d.sqlite")
        defer { Fixtures.cleanUp(url) }
        try await assertGateD(at: url)
    }

    private func assertGateD(at url: URL) async throws {
        // The live lifetime: run it, assert it, and let every store it created go out of
        // scope. Nothing below shares memory with it.
        let runID = try await runAndAssertLive(at: url)

        // The reopened lifetime. Everything from here reads the file.
        let reopened = try Stage2GateFixture.reopen(url)
        try assertClosedParentRun(in: reopened, runID: runID)

        let storedRun = try reopened.run(id: runID)
        let run = try #require(storedRun)

        // The frozen seed survived. It is what a later request would have to be sent
        // with, so a lost or rewritten seed is a lost run.
        #expect(run.requestConfigSeed.providerInstanceID == Stage2GateFixture.instanceID)
        #expect(run.requestConfigSeed.modelID == Stage2GateFixture.modelID)
        #expect(
            run.requestConfigSeed.credentialBinding.reference
                == Stage2GateFixture.credentialReference
        )
        #expect(run.requestConfigSeed.credentialBinding.generation == 1)

        // The execution snapshot survived, and still describes what the run was allowed
        // to do rather than what the process happens to expose now.
        let encodedSnapshot = try #require(run.executionSnapshot)
        let snapshot = try ExecutionSnapshotCodec.decode(encodedSnapshot)
        #expect(snapshot.providerID == .deepSeek)
        #expect(snapshot.modelCapabilities.contains(.text))
        #expect(snapshot.modelCapabilities.contains(.streaming))
        #expect(snapshot.modelCapabilities.contains(.tools))
        #expect(snapshot.exposedTools.map(\.toolID) == [CalculatorTool.toolID])
        #expect(
            snapshot.exposedTools.first?.inputSchema == CalculatorTool().descriptor.inputSchema
        )
        #expect(snapshot.maxProviderSteps == Stage2GateFixture.maxProviderSteps)
        #expect(snapshot.prompt.runtimeSafetyBaseline == "runtime-safety-v1")
    }

    // MARK: - Shared gate flow

    /// Drives one Gate A loop and asserts the closed run on the live connection, then
    /// lets the store go out of scope.
    ///
    /// The release is the point: it is what makes the caller's reopen a restart rather
    /// than a second handle onto a database this process never let go of.
    private func runAndAssertLive(at url: URL) async throws -> String {
        let components = try Stage2GateFixture.makeDiskComponents(at: url)
        let ledger = Stage2ProviderLedger()
        let runID = try await runCalculatorLoop(components: components, ledger: ledger)
        try assertClosedParentRun(in: components.store, runID: runID)
        return runID
    }

    /// One complete user -> model -> tool -> model send through the real
    /// `ConversationRuntime`, against whatever store the caller hands in.
    ///
    /// Gate A and Gate D drive the same loop, so the reopened database in Gate D is
    /// checked against a run the live runtime actually produced rather than against a
    /// hand-written row.
    private func runCalculatorLoop(
        components: Stage2GateFixture.Components,
        ledger: Stage2ProviderLedger
    ) async throws -> String {
        let provider = Stage2ScriptedProvider(
            ledger: ledger,
            scripts: [
                .events([
                    .toolCall(ProviderToolCall(
                        id: Self.providerCallID,
                        index: 0,
                        name: CalculatorTool.toolID,
                        argumentsJSON: #"{"expression":"6*7"}"#
                    )),
                    .finish(.toolCalls),
                ]),
                .events([
                    .textDelta(Self.finalAnswer),
                    .finish(.stop),
                ]),
            ]
        )
        let runtime = ConversationRuntime(
            store: components.store,
            provider: provider,
            credentials: components.credentials,
            toolRegistry: try ToolRegistry(tools: [CalculatorTool()])
        )
        return try await runtime.send(Stage2GateFixture.command(text: Self.question))
    }

    /// The claims Gate A and Gate D both make about one finished Parent Run.
    ///
    /// Both call this, so "the reopened database still satisfies the closure" is the
    /// same list of assertions as "the live one does" — not a weaker retelling of it.
    private func assertClosedParentRun(
        in store: PersistenceStore,
        runID: String
    ) throws {
        let storedRun = try store.run(id: runID)
        let run = try #require(
            storedRun,
            "the send must leave a durable Parent Run"
        )
        #expect(run.kind == .parent)
        #expect(run.parentRunID == nil)
        #expect(run.state == .completed)
        #expect(run.endReason == .completed)

        let messages = try store.messages(inConversation: Stage2GateFixture.conversationID)
        let userMessages = messages.filter { $0.role == .user }
        let assistantMessages = messages.filter { $0.role == .assistant }
        #expect(userMessages.count == 1, "one send produces exactly one trigger message")
        #expect(assistantMessages.count == 1, "one run produces exactly one assistant response")

        let responseID = try #require(
            run.responseMessageID,
            "a completed run binds its response message"
        )
        let assistant = try #require(assistantMessages.first)
        #expect(responseID == assistant.id)
        #expect(run.triggerMessageID == userMessages.first?.id)

        // One assistant message carries all three parts: the tool call, its result, and
        // the answer that follows it.
        let parts = try store.parts(ofMessage: assistant.id)
        #expect(parts.filter { $0.kind == .toolCall }.count == 1)
        #expect(parts.filter { $0.kind == .toolResult }.count == 1)
        #expect(parts.filter { $0.kind == .text }.count == 1)
        #expect(parts.allSatisfy { $0.state == .completed })

        let text = try parts
            .filter { $0.kind == .text }
            .compactMap { try store.text(ofPart: $0.id) }
            .joined()
        #expect(text == Self.finalAnswer)

        let calls = try store.toolCalls(inRun: runID)
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.providerCallID == Self.providerCallID)
        #expect(call.action == CalculatorTool.toolID)
        #expect(call.state == .succeeded)

        let storedResult = try store.toolResult(toolCallID: call.id)
        let result = try #require(
            storedResult,
            "a succeeded ToolCall must have its durable result"
        )
        #expect(result.payload == Self.toolResultPayload)

        // Tool message parts carry the durable ToolCall identity, not the provider's id.
        let callPart = try #require(parts.first { $0.kind == .toolCall })
        let resultPart = try #require(parts.first { $0.kind == .toolResult })
        #expect(try decodeToolCallPartID(callPart) == call.id)
        #expect(try decodeToolResultPartID(resultPart) == call.id)

        let steps = try store.steps(inRun: runID)
        #expect(steps.count == 2, "one durable step per provider request")
        #expect(steps.map(\.sequence) == [0, 1])
        #expect(steps.allSatisfy { $0.attempt == 1 })
        #expect(steps.map(\.stepID) == ["step-\(runID)-0", "step-\(runID)-1"])

        #expect(
            try store.activeParentRuns(inConversation: Stage2GateFixture.conversationID).isEmpty,
            "a completed run must not leave the conversation's active slot occupied"
        )
    }

    private func decodeToolCallPartID(_ part: MessagePartRecord) throws -> String {
        try JSONDecoder()
            .decode(ToolCallPartPayload.self, from: Data(part.payload.utf8))
            .toolCallID
    }

    private func decodeToolResultPartID(_ part: MessagePartRecord) throws -> String {
        try JSONDecoder()
            .decode(ToolResultPartPayload.self, from: Data(part.payload.utf8))
            .toolCallID
    }
}

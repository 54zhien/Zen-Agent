import Foundation
import Testing

@testable import ZenAgent

final class I05AttemptStreamBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<ProviderStreamEvent, Error>.Continuation?
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []
    private var requests = 0

    var requestCount: Int { lock.withLock { requests } }

    func makeStream() -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                self.continuation = continuation
                self.requests += 1
                let waiters = self.readyWaiters
                self.readyWaiters.removeAll()
                return waiters
            }
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    func waitUntilReady() async {
        let ready = lock.withLock { continuation != nil }
        if ready { return }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = lock.withLock {
                if self.continuation != nil {
                    return true
                }
                self.readyWaiters.append(continuation)
                return false
            }
            if ready {
                continuation.resume()
            }
        }
    }

    func yield(_ event: ProviderStreamEvent) {
        lock.withLock { continuation }?.yield(event)
    }

    func finish() {
        lock.withLock { continuation }?.finish()
    }
}

struct I05AttemptProvider: ModelProvider {
    let box: I05AttemptStreamBox
    let instanceID: ProviderInstanceID

    var id: ProviderID { .deepSeek }
    var adapterRevision: String { "i05-attempt-provider.v1" }
    var adapterPromptInstructions: String { "" }

    func knownModels(for instance: ProviderInstance) -> [ModelDescriptor] {
        [ModelDescriptor(
            id: I05RuntimeTestFixtures.modelID,
            providerInstanceID: instance.id,
            displayName: "Fake model",
            capabilities: [.text, .streaming]
        )]
    }

    func descriptor(for modelID: ModelID, in instance: ProviderInstance) -> ModelDescriptor? {
        knownModels(for: instance).first { $0.id == modelID }
    }

    func makeRequestConfigSeed(
        instance: ProviderInstance,
        modelID: ModelID,
        credentialBinding: CredentialBindingSnapshot
    ) throws -> RequestConfigSeed {
        guard descriptor(for: modelID, in: instance) != nil else {
            throw ProviderError.invalidRequest("unknown model")
        }
        return RequestConfigSeed(
            instance: instance,
            modelID: modelID,
            credentialBinding: credentialBinding,
            resolvedEndpoint: URL(string: "https://fake.invalid/chat/completions")!
        )
    }

    func stream(
        _ request: ProviderChatRequest,
        seed: RequestConfigSeed,
        credentials: any CredentialStoring
    ) async throws -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        box.makeStream()
    }
}

private enum I05ProjectionFailure: Error, Sendable {
    case rejected
}

private actor I05EventOrderRecorder {
    private var recordedEvents: [AgentEvent] = []

    func append(_ event: AgentEvent) {
        recordedEvents.append(event)
    }

    func events() -> [AgentEvent] {
        recordedEvents
    }
}

@Suite("Agent runtime streaming")
struct AgentRuntimeStreamingTests {

    private func snapshot(
        for provider: any ModelProvider,
        instance: ProviderInstance,
        maxProviderSteps: Int = 4
    ) -> RunExecutionSnapshot {
        RunExecutionSnapshot(
            providerID: provider.id,
            providerAdapterRevision: provider.adapterRevision,
            prompt: PromptExecutionSnapshot(
                runtimeSafetyBaseline: "runtime-safety-v1",
                zenCore: "zen-core-v1",
                providerAdapterInstructions: provider.adapterPromptInstructions
            ),
            modelCapabilities: [.text, .streaming],
            exposedTools: [],
            maxProviderSteps: maxProviderSteps
        )
    }

    @Test("multiple provider deltas are coalesced and terminal output is retained")
    func streamsTextThroughOneAgentStep() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let provider = FakeProvider(
            id: .deepSeek,
            instanceID: fixture.instance.id,
            modelNames: [I05RuntimeTestFixtures.modelID.rawValue],
            capabilities: [.text, .streaming],
            scriptedEvents: [
                .textDelta("one"),
                .textDelta(" two"),
                .textDelta(" three"),
                .finish(.stop),
            ]
        )
        try fixture.store.commitUserTurnAndCreateParentRun(
            Fixtures.send(
                conversationID: I05RuntimeTestFixtures.conversationID,
                messageID: "user-agent-stream",
                runID: "run-agent-stream"
            )
        )
        try fixture.store.completeExecutionSnapshot(
            runID: "run-agent-stream",
            encodedSnapshot: try ExecutionSnapshotCodec.encode(
                snapshot(for: provider, instance: fixture.instance)
            )
        )

        let runtime = AgentRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials
        )
        let request = ProviderChatRequest(
            modelID: I05RuntimeTestFixtures.modelID,
            messages: [.user("hello")]
        )
        let stream = await runtime.advance(
            runID: "run-agent-stream",
            request: request,
            snapshot: snapshot(for: provider, instance: fixture.instance)
        )

        var events: [AgentEvent] = []
        for try await event in stream {
            events.append(event)
        }

        let deltas = events.compactMap { event -> String? in
            guard case .messagePartDelta(_, _, let delta) = event else { return nil }
            return delta
        }
        #expect(deltas.joined() == "one two three")
        #expect(events.contains { event in
            if case .messagePartCompleted(_, _, .completed) = event { return true }
            return false
        })
        #expect(try fixture.store.steps(inRun: "run-agent-stream").count == 1)
        #expect(try fixture.store.run(id: "run-agent-stream")?.state == .completed)
    }

    @Test("the accumulator has an explicit terminal flush without a byte-sized contract")
    func accumulatorPreservesAllText() {
        var accumulator = StreamingAccumulator()
        var emitted = ""
        emitted += accumulator.append("alpha") ?? ""
        emitted += accumulator.append(" beta") ?? ""
        emitted += accumulator.append(" gamma") ?? ""
        emitted += accumulator.flush() ?? ""

        #expect(emitted == "alpha beta gamma")
        #expect(accumulator.flush() == nil)
    }

    @Test("a projection failure cannot leave a successful terminal run")
    func projectionFailureFailsTheRunAndStopsExecution() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let provider = FakeProvider(
            id: .deepSeek,
            instanceID: fixture.instance.id,
            modelNames: [I05RuntimeTestFixtures.modelID.rawValue],
            capabilities: [.text, .streaming],
            scriptedEvents: [
                .textDelta("output before projection failure"),
                .finish(.stop),
            ]
        )
        let snapshot = snapshot(for: provider, instance: fixture.instance)
        try fixture.store.commitUserTurnAndCreateParentRun(
            Fixtures.send(
                conversationID: I05RuntimeTestFixtures.conversationID,
                messageID: "user-agent-projection-failure",
                runID: "run-agent-projection-failure"
            )
        )
        try fixture.store.completeExecutionSnapshot(
            runID: "run-agent-projection-failure",
            encodedSnapshot: try ExecutionSnapshotCodec.encode(snapshot)
        )

        let runtime = AgentRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials
        )
        let stream = await runtime.advance(
            runID: "run-agent-projection-failure",
            request: ProviderChatRequest(
                modelID: I05RuntimeTestFixtures.modelID,
                messages: [.user("hello")]
            ),
            snapshot: snapshot,
            project: { event in
                if case .messagePartDelta = event {
                    throw I05ProjectionFailure.rejected
                }
            }
        )
        for try await _ in stream { }

        #expect(try fixture.store.run(id: "run-agent-projection-failure")?.state == .failed)
        #expect(
            try fixture.store.run(id: "run-agent-projection-failure")?.endReason == .providerFailed
        )
    }

    @Test("text is flushed before a tool request and survives unavailable-tools failure")
    func textToToolRequestedFlushesBeforeFailure() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let provider = FakeProvider(
            id: .deepSeek,
            instanceID: fixture.instance.id,
            modelNames: [I05RuntimeTestFixtures.modelID.rawValue],
            capabilities: [.text, .streaming],
            scriptedEvents: [
                .textDelta("partial before tool"),
                .toolCall(.init(
                    id: "tool-call-i05",
                    index: 0,
                    name: "unavailable-tool",
                    argumentsJSON: "{}"
                )),
            ]
        )
        let recorder = I05EventOrderRecorder()
        let runtime = ConversationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials,
            onEvent: { event in await recorder.append(event) }
        )

        let runID = try await runtime.send(I05RuntimeTestFixtures.command())
        let events = await recorder.events()
        guard let deltaIndex = events.firstIndex(where: { event in
            if case .messagePartDelta = event { return true }
            return false
        }) else {
            #expect(false, "text before a tool call must be projected")
            return
        }
        guard let toolRequestedIndex = events.firstIndex(where: { event in
            if case .runStateChanged(_, .toolRequested) = event { return true }
            return false
        }) else {
            #expect(false, "the tool call must enter toolRequested before the later failure")
            return
        }
        #expect(deltaIndex < toolRequestedIndex)

        guard let run = try fixture.store.run(id: runID),
              let responseID = run.responseMessageID else {
            #expect(false, "the partial assistant response must remain durable")
            return
        }
        let parts = try fixture.store.parts(ofMessage: responseID)
        #expect(parts.count == 1)
        #expect(try fixture.store.text(ofPart: parts[0].id) == "partial before tool")
        #expect(run.state == RunState.failed)
        #expect(run.endReason == EndReason.providerFailed)
    }

    @Test("a re-entry increments the durable attempt and rejects a late old-stream delta")
    func reentryUsesNewAttemptAndDropsLateDelta() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let box = I05AttemptStreamBox()
        let provider = I05AttemptProvider(box: box, instanceID: fixture.instance.id)
        let snapshot = snapshot(for: provider, instance: fixture.instance)
        try fixture.store.commitUserTurnAndCreateParentRun(
            Fixtures.send(
                conversationID: I05RuntimeTestFixtures.conversationID,
                messageID: "user-agent-attempt",
                runID: "run-agent-attempt"
            )
        )
        try fixture.store.completeExecutionSnapshot(
            runID: "run-agent-attempt",
            encodedSnapshot: try ExecutionSnapshotCodec.encode(snapshot)
        )
        try fixture.store.transitionRun(
            id: "run-agent-attempt",
            expectedState: .preparing,
            to: .requestingModel
        )
        let firstStep = AgentStepRecord(
            stepID: "step-run-agent-attempt-0",
            runID: "run-agent-attempt",
            sequence: 0,
            attempt: 1,
            createdAt: Date()
        )
        try fixture.store.recordStep(firstStep)
        try fixture.store.transitionRun(
            id: "run-agent-attempt",
            expectedState: .requestingModel,
            to: .streaming
        )

        let runtime = AgentRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials
        )
        let stream = await runtime.advance(
            runID: "run-agent-attempt",
            request: ProviderChatRequest(
                modelID: I05RuntimeTestFixtures.modelID,
                messages: [.user("hello")]
            ),
            snapshot: snapshot
        )

        await box.waitUntilReady()
        let attemptsAfterReentry = try fixture.store.steps(inRun: "run-agent-attempt")
        #expect(attemptsAfterReentry.map(\.attempt) == [1, 2])
        #expect(attemptsAfterReentry.map(\.sequence) == [0, 0])
        #expect(attemptsAfterReentry.allSatisfy { $0.stepID == firstStep.stepID })
        guard let secondAttempt = attemptsAfterReentry.last else {
            #expect(false, "re-entry must record a second provider attempt")
            return
        }
        #expect(try fixture.store.accepts(firstStep.attemptIdentity) == false)
        #expect(try fixture.store.accepts(secondAttempt.attemptIdentity))

        // Simulate a newer recovery owner taking the same logical step before the
        // old provider stream delivers its buffered delta.
        try fixture.store.recordStep(
            AgentStepRecord(
                stepID: secondAttempt.stepID,
                runID: secondAttempt.runID,
                sequence: secondAttempt.sequence,
                attempt: 3,
                createdAt: Date()
            )
        )
        box.yield(.textDelta("late old attempt"))
        box.finish()

        var events: [AgentEvent] = []
        for try await event in stream {
            events.append(event)
        }
        #expect(events.contains { event in
            if case .messagePartDelta = event { return true }
            return false
        } == false)
        #expect(try fixture.store.run(id: "run-agent-attempt")?.state == .streaming)
        #expect(box.requestCount == 1)
    }

    @Test("the durable step limit blocks provider execution and survives re-entry")
    func durableStepLimitIsNotResetOnReentry() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let box = I05AttemptStreamBox()
        let provider = I05AttemptProvider(box: box, instanceID: fixture.instance.id)
        let snapshot = snapshot(
            for: provider,
            instance: fixture.instance,
            maxProviderSteps: 1
        )
        try fixture.store.commitUserTurnAndCreateParentRun(
            Fixtures.send(
                conversationID: I05RuntimeTestFixtures.conversationID,
                messageID: "user-agent-limit",
                runID: "run-agent-limit"
            )
        )
        try fixture.store.completeExecutionSnapshot(
            runID: "run-agent-limit",
            encodedSnapshot: try ExecutionSnapshotCodec.encode(snapshot)
        )
        try fixture.store.recordStep(
            AgentStepRecord(
                stepID: "step-run-agent-limit-0",
                runID: "run-agent-limit",
                sequence: 0,
                attempt: 1,
                createdAt: Date()
            )
        )

        let runtime = AgentRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials
        )
        let request = ProviderChatRequest(
            modelID: I05RuntimeTestFixtures.modelID,
            messages: [.user("hello")]
        )
        let stream = await runtime.advance(
            runID: "run-agent-limit",
            request: request,
            snapshot: snapshot
        )
        for try await _ in stream { }

        #expect(box.requestCount == 0)
        #expect(try fixture.store.steps(inRun: "run-agent-limit").count == 1)
        #expect(try fixture.store.run(id: "run-agent-limit")?.state == .failed)
        #expect(try fixture.store.run(id: "run-agent-limit")?.endReason == .stepLimit)

        let reentry = await runtime.advance(
            runID: "run-agent-limit",
            request: request,
            snapshot: snapshot
        )
        for try await _ in reentry { }
        #expect(box.requestCount == 0)
        #expect(try fixture.store.steps(inRun: "run-agent-limit").count == 1)
        #expect(try fixture.store.run(id: "run-agent-limit")?.endReason == .stepLimit)
    }
}

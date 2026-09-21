import Foundation
import Testing

@testable import ZenAgent

@Suite("Agent runtime streaming")
struct AgentRuntimeStreamingTests {

    private func snapshot(for provider: any ModelProvider, instance: ProviderInstance) -> RunExecutionSnapshot {
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
            maxProviderSteps: 4
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
}

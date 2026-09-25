import Foundation
import Testing

@testable import ZenAgent

private final class StreamingOrderingTestClock: @unchecked Sendable {
    var instant: ContinuousClock.Instant = ContinuousClock.now
}

@Suite("Streaming event ordering")
@MainActor
struct StreamingEventOrderingTests {

    private func makeStore(clock: StreamingOrderingTestClock) -> LiveConversationStore {
        LiveConversationStore(
            projection: ConversationTimelineProjection(
                conversationID: "conversation-1",
                turns: [
                    ConversationTurn(runID: "run-1", items: [.userText("prompt")]),
                ]
            ),
            coalescer: StreamingCoalescer(interval: .milliseconds(10)),
            now: { clock.instant }
        )
    }

    @Test("started, delta, and completed preserve order and flush the final text")
    func startedDeltaCompleted() {
        let clock = StreamingOrderingTestClock()
        let store = makeStore(clock: clock)

        _ = store.consume(.messagePartStarted(
            runID: "run-1",
            messageID: "message-1",
            partID: "part-1",
            kind: .text
        ))
        #expect(store.state.activeParts["part-1"]?.state == .streaming)

        _ = store.consume(.messagePartDelta(
            runID: "run-1",
            partID: "part-1",
            delta: "hello",
            endUTF8Offset: 5
        ))

        _ = store.consume(.messagePartCompleted(
            runID: "run-1",
            partID: "part-1",
            state: .completed
        ))
        #expect(store.state.activeParts["part-1"]?.state == .completed)
        #expect(store.state.activeParts["part-1"]?.text == "hello")
        #expect(store.state.timeline.turns[0].textSourcesByItemIndex[1]?.partID == "part-1")
        #expect(store.state.timeline.turns[0].textSourcesByItemIndex[1]?.isCompleted == true)
    }

    @Test("a delta before started is dropped and counted")
    func deltaBeforeStartedIsCounted() {
        let clock = StreamingOrderingTestClock()
        let store = makeStore(clock: clock)

        _ = store.consume(.messagePartDelta(
            runID: "run-1",
            partID: "part-not-started",
            delta: "late",
            endUTF8Offset: 4
        ))

        #expect(store.droppedUnlocatableDeltas == 1)
    }
}

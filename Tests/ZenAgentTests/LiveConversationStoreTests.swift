import Foundation
import Testing

@testable import ZenAgent

private final class LiveStoreTestClock: @unchecked Sendable {
    var instant: ContinuousClock.Instant = ContinuousClock.now
}

@Suite("Live conversation store")
@MainActor
struct LiveConversationStoreTests {

    private func makeStore(
        turns: [ConversationTurn],
        interval: Duration = .milliseconds(10),
        clock: LiveStoreTestClock = LiveStoreTestClock()
    ) -> (store: LiveConversationStore, clock: LiveStoreTestClock) {
        let projection = ConversationTimelineProjection(
            conversationID: "conversation-1",
            turns: turns
        )
        let store = LiveConversationStore(
            projection: projection,
            coalescer: StreamingCoalescer(interval: interval),
            now: { clock.instant }
        )
        return (store, clock)
    }

    @Test("a delta rebuilds only its target Turn")
    func deltaOnlyRebuildsTargetTurn() {
        let initialTurns = [
            ConversationTurn(runID: "run-1", items: [.userText("one")]),
            ConversationTurn(runID: "run-2", items: [.userText("two")]),
            ConversationTurn(runID: "run-3", items: [.userText("three")]),
        ]
        let harness = makeStore(turns: initialTurns)

        _ = harness.store.consume(.messagePartStarted(
            runID: "run-2",
            messageID: "message-2",
            partID: "part-2",
            kind: .text
        ))
        _ = harness.store.consume(.messagePartDelta(
            runID: "run-2",
            partID: "part-2",
            delta: "li"
        ))
        harness.clock.instant = harness.clock.instant.advanced(by: .milliseconds(10))
        let rebuiltRuns = harness.store.consume(.messagePartDelta(
            runID: "run-2",
            partID: "part-2",
            delta: "ve"
        ))

        #expect(rebuiltRuns == Set<String>(["run-2"]))
        #expect(harness.store.state.timeline.turns[0] == initialTurns[0])
        #expect(harness.store.state.timeline.turns[2] == initialTurns[2])
    }

    @Test("completion flushes the final delta")
    func completionDoesNotDropFinalDelta() {
        let harness = makeStore(
            turns: [ConversationTurn(runID: "run-1", items: [.userText("prompt")])],
            interval: .seconds(1)
        )

        _ = harness.store.consume(.messagePartStarted(
            runID: "run-1",
            messageID: "message-1",
            partID: "part-1",
            kind: .text
        ))
        _ = harness.store.consume(.messagePartDelta(
            runID: "run-1",
            partID: "part-1",
            delta: "final"
        ))
        _ = harness.store.consume(.messagePartCompleted(
            runID: "run-1",
            partID: "part-1",
            state: .completed
        ))

        #expect(harness.store.state.activeParts["part-1"]?.text == "final")
        #expect(harness.store.state.timeline.turns[0].textSourcesByItemIndex[1]?.partID == "part-1")
        #expect(harness.store.state.timeline.turns[0].textSourcesByItemIndex[1]?.isCompleted == true)
    }

    @Test("runEnded flushes and clears the run's active parts")
    func runEndedFlushesAndCleansUp() {
        let harness = makeStore(
            turns: [ConversationTurn(runID: "run-1", items: [.userText("prompt")])],
            interval: .seconds(1)
        )

        _ = harness.store.consume(.messagePartStarted(
            runID: "run-1",
            messageID: "message-1",
            partID: "part-1",
            kind: .text
        ))
        _ = harness.store.consume(.messagePartDelta(
            runID: "run-1",
            partID: "part-1",
            delta: "tail"
        ))
        _ = harness.store.consume(.runEnded(
            runID: "run-1",
            state: .completed,
            endReason: .completed
        ))

        #expect(harness.store.state.timeline.turns[0].items.last == .assistantText("tail"))
        #expect(harness.store.state.activeParts.isEmpty)
    }

    @Test("a later text part grows at the end without changing the earlier text part")
    func messagePartsStayInTheirPositions() {
        let call = ToolCallPresentation(toolCallID: "tool-1", action: "write", state: .succeeded)
        let result = ToolResultPresentation(toolCallID: "tool-1", payload: "ok")
        let harness = makeStore(turns: [ConversationTurn(
            runID: "run-1",
            items: [
                .assistantText("before"),
                .toolCall(call),
                .toolResult(result),
            ]
        )])

        _ = harness.store.consume(.messagePartStarted(
            runID: "run-1",
            messageID: "message-1",
            partID: "part-after-tools",
            kind: .text
        ))
        _ = harness.store.consume(.messagePartDelta(
            runID: "run-1",
            partID: "part-after-tools",
            delta: "aft"
        ))
        harness.clock.instant = harness.clock.instant.advanced(by: .milliseconds(10))
        _ = harness.store.consume(.messagePartDelta(
            runID: "run-1",
            partID: "part-after-tools",
            delta: "er"
        ))

        #expect(harness.store.state.timeline.turns[0].items.first == .assistantText("before"))
        #expect(harness.store.state.timeline.turns[0].items.last == .assistantText("after"))
        #expect(harness.store.state.timeline.turns[0].textSourcesByItemIndex[3]?.partID == "part-after-tools")
        #expect(harness.store.state.timeline.turns[0].textSourcesByItemIndex[3]?.isCompleted == false)
    }

    @Test("a toolCall part does not create a live timeline item")
    func nonTextPartDoesNotCreateLiveItem() {
        let initialTurn = ConversationTurn(runID: "run-1", items: [.assistantText("before")])
        let harness = makeStore(turns: [initialTurn])

        let rebuiltRuns = harness.store.consume(.messagePartStarted(
            runID: "run-1",
            messageID: "message-1",
            partID: "tool-part-1",
            kind: .toolCall
        ))

        #expect(rebuiltRuns.isEmpty)
        #expect(harness.store.state.timeline.turns[0].items == initialTurn.items)
    }

    @Test("non-start events do not change the timeline")
    func nonStartEventsAreIgnoredByLiveTimeline() {
        let initialTurn = ConversationTurn(runID: "run-1", items: [.userText("prompt")])
        let harness = makeStore(turns: [initialTurn])

        #expect(harness.store.consume(.runStateChanged(runID: "run-1", state: .streaming)).isEmpty)
        #expect(harness.store.consume(.toolCallChanged(
            runID: "run-1",
            providerCallID: "provider-call-1",
            state: .succeeded
        )).isEmpty)
        #expect(harness.store.consume(.approvalRequired(
            runID: "run-1",
            toolCallID: "tool-call-1"
        )).isEmpty)
        #expect(harness.store.state.timeline.turns[0] == initialTurn)
    }
}

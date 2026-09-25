import Foundation
import Testing

@testable import ZenAgent

@Suite("Run event routing across Pane remount")
@MainActor
struct RunEventRouterRemountTests {
    @Test("an active text Part keeps updating after its Conversation Pane is remounted")
    func activePartContinuesAfterRemount() async throws {
        let conversationID = "remount-conversation"
        let runID = "remount-run"
        let messageID = "remount-message"
        let partID = "remount-part"
        var durableText = ""
        var durablePartCompleted = false
        let router = RunEventRouter()

        func projection() -> ConversationTimelineProjection {
            var items: [TimelineItem] = [.userText("question")]
            var sources: [Int: TimelineTextSource] = [:]
            if !durableText.isEmpty {
                sources[items.count] = TimelineTextSource(
                    conversationID: conversationID,
                    messageID: messageID,
                    partID: partID,
                    isCompleted: durablePartCompleted
                )
                items.append(.assistantText(durableText))
            }
            return ConversationTimelineProjection(
                conversationID: conversationID,
                turns: [ConversationTurn(
                    runID: runID,
                    items: items,
                    textSourcesByItemIndex: sources
                )]
            )
        }

        func pane() throws -> ConversationPaneController {
            try ConversationPaneController(
                conversationID: conversationID,
                initialTimeline: projection(),
                configuration: ConversationComposerConfiguration(
                    providerInstanceID: ProviderInstanceID(rawValue: "remount-provider"),
                    modelID: ModelID(rawValue: "remount-model")
                ),
                coalescer: StreamingCoalescer(interval: .milliseconds(0)),
                loadTimeline: { _ in projection() }
            )
        }

        let firstPane = try pane()
        #expect(router.registerPane(firstPane))
        await router.handle(.runAccepted(runID: runID, conversationID: conversationID))
        await router.handle(.messagePartStarted(
            runID: runID,
            messageID: messageID,
            partID: partID,
            kind: .text
        ))
        durableText = "hello"
        await router.handle(.messagePartDelta(runID: runID, partID: partID, delta: "hello"))
        #expect(assistantText(in: firstPane) == "hello")

        router.unregisterPane(for: conversationID)
        durableText = "hello world"
        await router.handle(.messagePartDelta(runID: runID, partID: partID, delta: " world"))

        let secondPane = try pane()
        #expect(router.registerPane(secondPane))
        #expect(assistantText(in: secondPane) == "hello world")

        durableText = "hello world!"
        await router.handle(.messagePartDelta(runID: runID, partID: partID, delta: "!"))
        durablePartCompleted = true
        await router.handle(.messagePartCompleted(runID: runID, partID: partID, state: .completed))
        await router.handle(.runEnded(runID: runID, state: .completed, endReason: .completed))

        #expect(assistantText(in: secondPane) == "hello world!")
        #expect(secondPane.liveStore.droppedUnlocatableDeltas == 0)
        #expect(secondPane.liveStore.state.activeParts.isEmpty)
    }

    @Test("a delta persisted before remount but published afterward appears exactly once")
    func persistedBeforePublishDoesNotDuplicate() async throws {
        let conversationID = "inflight-conversation"
        let runID = "inflight-run"
        let partID = "inflight-part"
        var durableText = ""
        let router = RunEventRouter()

        func projection() -> ConversationTimelineProjection {
            var items: [TimelineItem] = [.userText("question")]
            var sources: [Int: TimelineTextSource] = [:]
            if !durableText.isEmpty {
                sources[1] = TimelineTextSource(
                    conversationID: conversationID,
                    messageID: "inflight-message",
                    partID: partID,
                    isCompleted: false
                )
                items.append(.assistantText(durableText))
            }
            return ConversationTimelineProjection(
                conversationID: conversationID,
                turns: [ConversationTurn(
                    runID: runID,
                    items: items,
                    textSourcesByItemIndex: sources
                )]
            )
        }

        func pane() throws -> ConversationPaneController {
            try ConversationPaneController(
                conversationID: conversationID,
                initialTimeline: projection(),
                configuration: ConversationComposerConfiguration(
                    providerInstanceID: ProviderInstanceID(rawValue: "inflight-provider"),
                    modelID: ModelID(rawValue: "inflight-model")
                ),
                coalescer: StreamingCoalescer(interval: .milliseconds(0)),
                loadTimeline: { _ in projection() }
            )
        }

        let firstPane = try pane()
        #expect(router.registerPane(firstPane))
        await router.handle(.runAccepted(runID: runID, conversationID: conversationID))
        await router.handle(.messagePartStarted(
            runID: runID,
            messageID: "inflight-message",
            partID: partID,
            kind: .text
        ))
        durableText = "repeat"
        await router.handle(.messagePartDelta(runID: runID, partID: partID, delta: "repeat"))
        router.unregisterPane(for: conversationID)

        // Projection has committed the next delta, but Router has not seen it yet.
        durableText = "repeatrepeat"
        let secondPane = try pane()
        #expect(router.registerPane(secondPane))
        await router.handle(.messagePartDelta(runID: runID, partID: partID, delta: "repeat"))

        #expect(assistantText(in: secondPane) == "repeatrepeat")
        #expect(secondPane.liveStore.droppedUnlocatableDeltas == 0)
    }

    private func assistantText(in pane: ConversationPaneController) -> String? {
        pane.liveStore.state.timeline.turns.flatMap(\.items).compactMap { (item: TimelineItem) -> String? in
            guard case .assistantText(let text) = item else { return nil }
            return text
        }.last
    }
}

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

    @Test("recovery snapshot ahead of a pending delta does not append it twice")
    func recoverySnapshotAheadOfPendingDelta() async throws {
        let conversationID = "snapshot-ahead-conversation"
        let runID = "snapshot-ahead-run"
        let messageID = "snapshot-ahead-message"
        let partID = "snapshot-ahead-part"
        var durableText = ""
        var loadCount = 0
        let router = RunEventRouter()

        func projection() -> ConversationTimelineProjection {
            ConversationTimelineProjection(
                conversationID: conversationID,
                turns: [ConversationTurn(
                    runID: runID,
                    items: [.userText("question"), .assistantText(durableText)],
                    textSourcesByItemIndex: [1: TimelineTextSource(
                        conversationID: conversationID,
                        messageID: messageID,
                        partID: partID,
                        isCompleted: false
                    )]
                )]
            )
        }

        let pane = try ConversationPaneController(
            conversationID: conversationID,
            initialTimeline: ConversationTimelineProjection(conversationID: conversationID, turns: []),
            configuration: ConversationComposerConfiguration(
                providerInstanceID: ProviderInstanceID(rawValue: "snapshot-ahead-provider"),
                modelID: ModelID(rawValue: "snapshot-ahead-model")
            ),
            coalescer: StreamingCoalescer(interval: .milliseconds(0)),
            loadTimeline: { _ in
                loadCount += 1
                if loadCount == 1 { throw SnapshotLoadFailure.unavailable }
                return projection()
            }
        )

        #expect(router.registerPane(pane))
        await router.handle(.runAccepted(runID: runID, conversationID: conversationID))
        await router.handle(.messagePartStarted(
            runID: runID,
            messageID: messageID,
            partID: partID,
            kind: .text
        ))
        durableText = "one"
        await router.handle(.messagePartDelta(runID: runID, partID: partID, delta: "one"))

        // Persistence commits this delta before its event reaches the router.
        durableText = "onetwo"
        #expect(router.retryTimelineLoad(for: conversationID))
        await router.handle(.messagePartDelta(runID: runID, partID: partID, delta: "two"))
        #expect(assistantText(in: pane) == "onetwo")

        durableText = "onetwothree"
        await router.handle(.messagePartDelta(runID: runID, partID: partID, delta: "three"))
        #expect(assistantText(in: pane) == "onetwothree")
        #expect(pane.liveStore.droppedUnlocatableDeltas == 0)
    }

    private enum SnapshotLoadFailure: Error {
        case unavailable
    }

    private func assistantText(in pane: ConversationPaneController) -> String? {
        pane.liveStore.state.timeline.turns.flatMap(\.items).compactMap { (item: TimelineItem) -> String? in
            guard case .assistantText(let text) = item else { return nil }
            return text
        }.last
    }
}

import Foundation
import Testing

@testable import ZenAgent

@Suite("Run event routing across Pane remount")
@MainActor
struct RunEventRouterRemountTests {
    @Test("an invisible active Run does not retain its Full Pane or live store")
    func invisibleActiveRunReleasesPane() async throws {
        let router = RunEventRouter()
        let conversationID = "released-active-conversation"
        let runID = "released-active-run"
        var pane: ConversationPaneController? = try ConversationPaneController(
            conversationID: conversationID,
            initialTimeline: ConversationTimelineProjection(conversationID: conversationID, turns: []),
            configuration: nil,
            coalescer: StreamingCoalescer(interval: .milliseconds(0)),
            loadTimeline: { id in
                ConversationTimelineProjection(conversationID: id,
                    turns: [ConversationTurn(runID: runID, items: [.userText("question")])])
            }
        )
        weak var releasedPane = pane
        #expect(router.registerPane(try #require(pane)))
        await router.handle(.runAccepted(runID: runID, conversationID: conversationID))
        await router.handle(.messagePartStarted(runID: runID, messageID: "released-message",
            partID: "released-part", kind: .text))
        // runAccepted replaces the initial store. Capture the actual live store,
        // not the already-released pre-load value.
        weak var releasedStore = pane?.liveStore
        router.unregisterPane(for: conversationID)
        pane = nil
        #expect(releasedPane == nil)
        #expect(releasedStore == nil)
        // UI detachment is not a Run cancellation or an ownership loss.
        await router.handle(.messagePartDelta(runID: runID, partID: "released-part",
            delta: "still running", endUTF8Offset: 13))
        #expect(!router.diagnostics.contains("Dropped unregistered Run event for \(runID)"))
    }

    @Test("unfinished persisted display Parts resume by stable identity and UTF8 offset",
          arguments: [MessagePartKind.text, .reasoning])
    func persistedDisplayPartResumes(kind: MessagePartKind) throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.commitUserTurnAndCreateParentRun(Fixtures.send(messageID: "resume-user", runID: "resume-run"))
        _ = try store.ensureAssistantResponse(forRunID: "resume-run", messageID: "resume-response")
        var part = Fixtures.textPart(id: "resume-part", messageID: "resume-response", text: "开头")
        part.kind = kind
        part.state = .streaming
        try store.createPart(part)
        let projection = try ConversationTimelineLoader.load(conversationID: "c1", from: store)
        #expect(projection.turns[0].textSourcesByItemIndex[1]?.partID == part.id)
        let live = LiveConversationStore(projection: projection,
            coalescer: StreamingCoalescer(interval: .milliseconds(0)))
        #expect(live.resumePersistedPart(runID: "resume-run", messageID: "resume-response",
            partID: part.id, kind: kind))

        // Runtime's acknowledged persistence boundary commits before publication.
        try store.appendText(toPart: part.id, delta: "后续")
        _ = live.consume(.messagePartDelta(runID: "resume-run", partID: part.id,
            delta: "后续", endUTF8Offset: "开头后续".utf8.count))
        #expect(live.state.timeline.turns[0].items == [
            .userText("hello"), kind == .text ? .assistantText("开头后续") : .reasoning("开头后续")])
        #expect(live.droppedUnlocatableDeltas == 0)
        // An event already represented by the offset cannot duplicate either kind.
        _ = live.consume(.messagePartDelta(runID: "resume-run", partID: part.id,
            delta: "后续", endUTF8Offset: "开头后续".utf8.count))
        #expect(live.state.activeParts[part.id]?.text == "开头后续")
        try store.finishPart(id: part.id, state: .completed)
        _ = live.consume(.messagePartCompleted(runID: "resume-run", partID: part.id, state: .completed))
        _ = live.consume(.runEnded(runID: "resume-run", state: .completed, endReason: .completed))
        #expect(live.state.activeParts.isEmpty)
    }

    @Test("terminal persisted Parts cannot be resurrected while their parent is active",
          arguments: [MessagePartState.completed, .failed, .cancelled])
    func terminalPersistedPartCannotResume(partState: MessagePartState) throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.commitUserTurnAndCreateParentRun(Fixtures.send(messageID: "terminal-user", runID: "terminal-run"))
        _ = try store.ensureAssistantResponse(forRunID: "terminal-run", messageID: "terminal-response")
        var part = Fixtures.textPart(id: "terminal-part", messageID: "terminal-response", text: "saved")
        part.state = partState
        try store.createPart(part)
        let live = LiveConversationStore(
            projection: try ConversationTimelineLoader.load(conversationID: "c1", from: store),
            coalescer: StreamingCoalescer(interval: .milliseconds(0)))
        #expect(!live.resumePersistedPart(runID: "terminal-run", messageID: part.messageID,
            partID: part.id, kind: .text))
        #expect(live.state.activeParts.isEmpty)
        #expect(live.state.timeline.turns[0].items == [.userText("hello"), .assistantText("saved")])
    }

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
        await router.handle(.messagePartDelta(runID: runID, partID: partID, delta: "hello", endUTF8Offset: 5))
        #expect(assistantText(in: firstPane) == "hello")

        router.unregisterPane(for: conversationID)
        durableText = "hello world"
        await router.handle(.messagePartDelta(runID: runID, partID: partID, delta: " world", endUTF8Offset: 11))

        // An outgoing display must stop consuming token events; the durable
        // projection below is the source for its next mount.
        #expect(assistantText(in: firstPane) == "hello")

        let secondPane = try pane()
        #expect(router.registerPane(secondPane))
        #expect(assistantText(in: secondPane) == "hello world")

        durableText = "hello world!"
        await router.handle(.messagePartDelta(runID: runID, partID: partID, delta: "!", endUTF8Offset: 12))
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
        await router.handle(.messagePartDelta(runID: runID, partID: partID, delta: "repeat", endUTF8Offset: 6))
        router.unregisterPane(for: conversationID)

        // Projection has committed the next delta, but Router has not seen it yet.
        durableText = "repeatrepeat"
        let secondPane = try pane()
        #expect(router.registerPane(secondPane))
        await router.handle(.messagePartDelta(runID: runID, partID: partID, delta: "repeat", endUTF8Offset: 12))

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
        await router.handle(.messagePartDelta(runID: runID, partID: partID, delta: "one", endUTF8Offset: 3))

        // Persistence commits this delta before its event reaches the router.
        durableText = "onetwo"
        #expect(router.retryTimelineLoad(for: conversationID))
        await router.handle(.messagePartDelta(runID: runID, partID: partID, delta: "two", endUTF8Offset: 6))
        #expect(assistantText(in: pane) == "onetwo")

        durableText = "onetwothree"
        await router.handle(.messagePartDelta(runID: runID, partID: partID, delta: "three", endUTF8Offset: 11))
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

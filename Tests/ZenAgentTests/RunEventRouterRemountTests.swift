import Foundation
import Testing

@testable import ZenAgent

@Suite("Run event routing across Pane remount")
@MainActor
struct RunEventRouterRemountTests {
    @Test("handoff publishes a journal suffix while its Part is still streaming")
    func handoffPublishesUnfinishedSuffix() async throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let id = "unfinished-handoff"
        let run = "unfinished-run"
        let part = "unfinished-part"
        try store.commitUserTurnAndCreateParentRun(Fixtures.send(conversationID: id,
            messageID: "unfinished-user", runID: run, runState: .streaming))
        _ = try store.ensureAssistantResponse(forRunID: run, messageID: "unfinished-assistant")
        try store.createPart(Fixtures.streamingPart(id: part, messageID: "unfinished-assistant", text: "before"))
        let projection = try ConversationTimelineLoader.load(conversationID: id, from: store)
        let pane = try ConversationPaneController(conversationID: id, initialTimeline: projection,
            configuration: nil, coalescer: StreamingCoalescer(interval: .milliseconds(10)))
        let instant = ContinuousClock.now
        try pane.adoptLiveStore(LiveConversationStore(projection: projection,
            coalescer: StreamingCoalescer(interval: .milliseconds(10)), now: { instant }))
        let router = RunEventRouter()
        router.registerRecoveredRun(runID: run, conversationID: id)
        let ticket = router.beginPanePreparation(for: id)
        await router.handle(.messagePartDelta(runID: run, partID: part, delta: "你好👋",
            endUTF8Offset: "before你好👋".utf8.count))
        #expect(router.registerPreparedPane(pane, ticket: ticket))
        #expect(pane.liveStore.state.timeline.turns.flatMap(\.items).contains(.assistantText("before你好👋")))
        #expect(pane.liveStore.state.activeParts[part]?.state == .streaming)
        #expect(router.hasActiveRun(for: id))
        #expect(!pane.liveStore.needsTimelineReload)
    }

    @Test("a completed snapshot Part is not inserted again by a late durable Start")
    func completedSnapshotPrecedesStart() async throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let id = "late-start-conversation"
        let run = "late-start-run"
        let message = "late-start-assistant"
        let part = "late-start-part"
        let text = "你好👋"
        try store.commitUserTurnAndCreateParentRun(Fixtures.send(conversationID: id,
            messageID: "late-start-user", runID: run, runState: .streaming))
        _ = try store.ensureAssistantResponse(forRunID: run, messageID: message)
        try store.createPart(Fixtures.streamingPart(id: part, messageID: message, text: text))
        try store.finishPart(id: part, state: .completed)
        let router = RunEventRouter()
        router.registerRecoveredRun(runID: run, conversationID: id)
        let pane = try ConversationPaneController(conversationID: id,
            initialTimeline: ConversationTimelineLoader.load(conversationID: id, from: store),
            configuration: nil, coalescer: StreamingCoalescer(interval: .milliseconds(0)),
            loadTimeline: { try ConversationTimelineLoader.load(conversationID: $0, from: store) })
        #expect(router.registerPane(pane))
        // Persistence can be ahead of the event's main-actor delivery.
        await router.handle(.messagePartStarted(runID: run, messageID: message, partID: part, kind: .text))
        await router.handle(.messagePartDelta(runID: run, partID: part, delta: text, endUTF8Offset: text.utf8.count))
        await router.handle(.messagePartCompleted(runID: run, partID: part, state: .completed))
        try store.transitionRun(id: run, expectedState: .streaming, to: .completed, endReason: .completed)
        await router.handle(.runEnded(runID: run, state: .completed, endReason: .completed))
        let texts = pane.liveStore.state.timeline.turns.flatMap(\.items).compactMap { item -> String? in
            if case .assistantText(let text) = item { return text }
            return nil
        }
        #expect(texts == [text])
        #expect(pane.liveStore.state.activeParts.isEmpty)
        #expect(pane.liveStore.droppedUnlocatableDeltas == 0)
    }

    @Test("a real Run settling while detached remounts its durable terminal outcome",
          .timeLimit(.minutes(1)), arguments: [false, true])
    func runtimeSettlesWhileDetached(cancel: Bool) async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let box = I05AttemptStreamBox()
        let recorder = I05EventRecorder()
        let router = RunEventRouter()
        let runtime = ConversationRuntime(store: fixture.store,
            provider: I05AttemptProvider(box: box, instanceID: fixture.instance.id), credentials: fixture.credentials,
            onEvent: { event in
                await router.handle(event)
                await recorder.append(event)
            }, toolRegistry: .empty)
        let id = I05RuntimeTestFixtures.conversationID
        func makePane() throws -> ConversationPaneController {
            try ConversationPaneController(conversationID: id,
                initialTimeline: try ConversationTimelineLoader.load(conversationID: id, from: fixture.store),
                configuration: nil, coalescer: StreamingCoalescer(interval: .milliseconds(0)),
                loadTimeline: { try ConversationTimelineLoader.load(conversationID: $0, from: fixture.store) })
        }
        let first = try makePane()
        #expect(router.registerPane(first))
        let runID = try await runtime.start(I05RuntimeTestFixtures.command())
        await box.waitUntilReady()
        let text = String(repeating: "partial", count: 200)
        box.yield(.textDelta(text))
        _ = await recorder.waitForFirstDelta()
        router.unregisterPane(for: id)
        if cancel {
            try await runtime.stop(runID: runID)
        } else {
            box.yield(.finish(.stop))
            box.finish()
        }
        try await runtime.waitForCompletion(runID: runID)
        let second = try makePane()
        #expect(router.registerPane(second))
        #expect(assistantText(in: second) == text)
        #expect(second.liveStore.state.activeParts.isEmpty)
        #expect(second.liveStore.droppedUnlocatableDeltas == 0)
        #expect(try fixture.store.run(id: runID)?.state == (cancel ? .cancelled : .completed))
        let notices = second.liveStore.state.timeline.turns[0].items.compactMap { item -> RunNoticePresentation? in
            guard case .runNotice(let notice) = item else { return nil }
            return notice
        }
        #expect(notices == (cancel ? [RunNoticePresentation(runID: runID, state: .cancelled,
            endReason: .cancelledByUser)] : []))
        #expect(router.diagnostics.isEmpty)
    }

    @Test("real Runtime persists a thousand detached deltas and resumes the active display",
          .timeLimit(.minutes(1)))
    func runtimeDetachedLongStream() async throws {
        let url = try Fixtures.scratchPath(name: "s504-detached-stream.sqlite")
        defer { Fixtures.cleanUp(url) }
        try await assertRuntimeDetachedLongStream(at: url)
    }

    private func assertRuntimeDetachedLongStream(at url: URL) async throws {
        let components = try Stage2GateFixture.makeDiskComponents(at: url)
        let box = Stage2StreamBox()
        let recorder = I05EventRecorder()
        let deltas = S504DeltaBarrier()
        let router = RunEventRouter()
        // Large fixture chunks cross today's private persistence batching policy;
        // their size is not a product or UI latency contract.
        let chunk = String(repeating: "中", count: 400)
        let prefix = "start" + chunk
        let runtime = ConversationRuntime(store: components.store,
            provider: Stage2ScriptedProvider(ledger: Stage2ProviderLedger(),
                scripts: [.holding(prefix: [.textDelta(prefix)], box: box)]),
            credentials: components.credentials, onEvent: { event in
                await router.handle(event)
                await recorder.append(event)
                await deltas.observe(event)
            }, toolRegistry: .empty)
        let id = Stage2GateFixture.conversationID
        func makePane() throws -> ConversationPaneController {
            try ConversationPaneController(conversationID: id,
                initialTimeline: try ConversationTimelineLoader.load(conversationID: id, from: components.store),
                configuration: nil, coalescer: StreamingCoalescer(interval: .milliseconds(0)),
                loadTimeline: { try ConversationTimelineLoader.load(conversationID: $0, from: components.store) })
        }
        var pane: ConversationPaneController? = try makePane()
        #expect(router.registerPane(try #require(pane)))
        let runID = try await runtime.start(Stage2GateFixture.command(text: "background stream"))
        _ = await recorder.waitForFirstDelta()
        weak var oldPane = pane
        weak var oldStore = pane?.liveStore
        router.unregisterPane(for: id)
        pane = nil
        #expect(oldPane == nil)
        #expect(oldStore == nil)
        for _ in 0..<1_000 { box.yieldLate(.textDelta(chunk)) }
        let saved = prefix + String(repeating: chunk, count: 1_000)
        await deltas.wait(for: saved.utf8.count)
        let remounted = try makePane()
        #expect(router.registerPane(remounted))
        #expect(assistantText(in: remounted) == saved)
        #expect(remounted.liveStore.state.activeParts.count == 1)
        #expect(await runtime.activeOperationCount == 1)
        box.yieldLate(.textDelta("+live"))
        box.yieldLate(.finish(.stop))
        try await runtime.waitForCompletion(runID: runID)
        #expect(assistantText(in: remounted) == saved + "+live")
        #expect(remounted.liveStore.state.activeParts.isEmpty)
        #expect(remounted.liveStore.droppedUnlocatableDeltas == 0)
        #expect(try components.store.run(id: runID)?.state == .completed)
        let reopened = try Stage2GateFixture.reopen(url)
        let final = try ConversationTimelineLoader.load(conversationID: id, from: reopened)
        #expect(final.turns[0].items.contains(.assistantText(saved + "+live")))
        #expect(router.diagnostics.isEmpty)
    }

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
        #expect(await router.retryTimelineLoad(for: conversationID))
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

private actor S504DeltaBarrier {
    private var byteCount = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func observe(_ event: AgentEvent) {
        guard case .messagePartDelta(_, _, let text, _) = event else { return }
        byteCount += text.utf8.count
        let ready = waiters.filter { $0.0 <= byteCount }
        waiters.removeAll { $0.0 <= byteCount }
        for (_, waiter) in ready { waiter.resume() }
    }

    func wait(for target: Int) async {
        guard byteCount < target else { return }
        await withCheckedContinuation { waiters.append((target, $0)) }
    }
}

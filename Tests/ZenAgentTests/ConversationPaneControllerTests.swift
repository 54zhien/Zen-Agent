import Foundation
import GRDB
import Testing

@testable import ZenAgent

private enum ConversationPaneLoaderProbeError: Error, Equatable {
    case unavailable
}

private struct ConversationPaneApprovalEnvironment {
    let store: PersistenceStore
    let credentials: CredentialStore
}

@Suite("Reusable conversation pane controller")
@MainActor
struct ConversationPaneControllerTests {

    @Test
    func rejectsMismatchedInitialTimeline() throws {
        let mismatchedTimeline = ConversationTimelineProjection(
            conversationID: "timeline-owner-b",
            turns: []
        )

        #expect(throws: ConversationPaneError.mismatchedTimeline(
            expected: "pane-owner-a",
            actual: "timeline-owner-b"
        )) {
            try makePane(
                conversationID: "pane-owner-a",
                initialTimeline: mismatchedTimeline
            )
        }
    }

    @Test
    func foreignEventLeavesEveryPaneStateUnchanged() throws {
        let initialTurn = ConversationTurn(runID: "pane-run-a", items: [.userText("prompt A")])
        let pane = try makePane(conversationID: "pane-a", turns: [initialTurn])
        let approval = makeApproval(
            toolCallID: "approval-a",
            conversationID: "pane-a"
        )
        pane.liveStore.reconcilePendingToolApprovals([approval])
        let originalDraft = makeDraft(text: "draft A", selection: 2..<2)
        pane.composer.draft = originalDraft

        let geometry = ScrollGeometry(viewportHeight: 300, contentHeight: 1_000, offset: 500)
        let anchor = TurnAnchor(runID: "pane-run-a", relativeViewportOffset: -0.25)
        _ = pane.updateReading(.userScrolled(geometry: geometry, anchor: anchor))
        _ = pane.updateReading(.contentChanged(changedRunIDs: ["queued-before-foreign-event"]))

        let originalLiveState = pane.liveStore.state
        let originalNeedsReconciliation = pane.liveStore.needsPendingToolApprovalReconciliation
        let originalReadingMode = pane.readingPosition.mode
        let originalScrollRequest = pane.scrollRequest

        let timelineResult = try pane.consume(
            .messagePartStarted(
                runID: "pane-run-a",
                messageID: "foreign-message",
                partID: "foreign-part",
                kind: .text
            ),
            in: "pane-b"
        )
        let approvalResult = try pane.consume(
            .approvalRequired(runID: "pane-run-a", toolCallID: "foreign-approval"),
            in: "pane-b"
        )

        #expect(timelineResult.isEmpty)
        #expect(approvalResult.isEmpty)
        #expect(pane.liveStore.state == originalLiveState)
        #expect(pane.liveStore.needsPendingToolApprovalReconciliation == originalNeedsReconciliation)
        #expect(pane.liveStore.state.pendingToolApprovals == [approval])
        #expect(pane.composer.draft == originalDraft)
        #expect(pane.readingPosition.mode == originalReadingMode)
        #expect(pane.scrollRequest == originalScrollRequest)
    }

    @Test
    func runAcceptedAddsTurnWithoutReplacingDraftOrReadingMode() throws {
        let originalTurn = ConversationTurn(runID: "existing-run", items: [.userText("existing")])
        let addedTurn = ConversationTurn(runID: "accepted-run", items: [.userText("new")])
        let loadedTimeline = ConversationTimelineProjection(
            conversationID: "pane-run",
            turns: [originalTurn, addedTurn]
        )
        var loadedConversationIDs: [String] = []
        let pane = try makePane(
            conversationID: "pane-run",
            turns: [originalTurn],
            loadTimeline: { requestedConversationID in
                loadedConversationIDs.append(requestedConversationID)
                return loadedTimeline
            }
        )
        let composer = pane.composer
        let readingPosition = pane.readingPosition
        let originalDraft = makeDraft(text: "keep this draft", selection: 5..<5)
        pane.composer.draft = originalDraft

        let geometry = ScrollGeometry(viewportHeight: 400, contentHeight: 1_000, offset: 300)
        let anchor = TurnAnchor(runID: "existing-run", relativeViewportOffset: -0.125)
        _ = pane.updateReading(.userScrolled(
            geometry: geometry,
            anchor: anchor
        ))

        let changedRuns = try pane.consume(
            .runAccepted(runID: "accepted-run", conversationID: "pane-run"),
            in: "pane-run"
        )

        #expect(loadedConversationIDs == ["pane-run"])
        #expect(changedRuns == Set<String>(["accepted-run"]))
        #expect(pane.liveStore.state.timeline.turns.map(\.runID) == ["existing-run", "accepted-run"])
        #expect(pane.composer === composer)
        #expect(pane.composer.draft == originalDraft)
        #expect(pane.readingPosition === readingPosition)
        #expect(pane.readingPosition.mode == .reading(anchor: anchor, pendingTurns: ["accepted-run"]))

        let request = try #require(pane.scrollRequest)
        #expect(request.action == .restoreAnchor(anchor))
        let appliedGeometry = applying(
            request.action,
            to: geometry,
            turnTops: ["existing-run": 250]
        )
        #expect(appliedGeometry.offset == 300)
        _ = pane.updateReading(.programmaticScrolled(geometry: appliedGeometry))
        pane.markScrollApplied(sequence: request.sequence)
        #expect(pane.scrollRequest == nil)
        #expect(pane.readingPosition.mode == .reading(anchor: anchor, pendingTurns: ["accepted-run"]))
    }

    @Test
    func loaderFailurePreservesStateAndRetryAddsRunOnce() throws {
        let originalTurn = ConversationTurn(runID: "stable-run", items: [.userText("stable")])
        let retriedTurn = ConversationTurn(runID: "retry-run", items: [.userText("loaded once")])
        let retryTimeline = ConversationTimelineProjection(
            conversationID: "retry-owner",
            turns: [originalTurn, retriedTurn]
        )
        var loadCount = 0
        let pane = try makePane(
            conversationID: "retry-owner",
            turns: [originalTurn],
            loadTimeline: { requestedConversationID in
                loadCount += 1
                if loadCount == 1 {
                    throw ConversationPaneLoaderProbeError.unavailable
                }
                return retryTimeline
            }
        )
        let originalStore = pane.liveStore
        let originalComposer = pane.composer
        let originalReadingPosition = pane.readingPosition
        let originalDraft = makeDraft(text: "survives loader failure", selection: 7..<7)
        pane.composer.draft = originalDraft
        let geometry = ScrollGeometry(viewportHeight: 400, contentHeight: 1_000, offset: 300)
        let anchor = TurnAnchor(runID: "stable-run", relativeViewportOffset: -0.125)
        _ = pane.updateReading(.userScrolled(geometry: geometry, anchor: anchor))
        _ = pane.updateReading(.contentChanged(changedRunIDs: ["already-pending-run"]))
        let originalReadingMode = pane.readingPosition.mode
        let originalScrollRequest = pane.scrollRequest

        var caughtError: Error?
        do {
            _ = try pane.consume(
                .runAccepted(runID: "retry-run", conversationID: "retry-owner"),
                in: "retry-owner"
            )
        } catch {
            caughtError = error
        }

        #expect((caughtError as? ConversationPaneLoaderProbeError) == .unavailable)
        #expect(loadCount == 1)
        #expect(pane.liveStore === originalStore)
        #expect(pane.liveStore.state.timeline.turns.map(\.runID) == ["stable-run"])
        #expect(pane.composer === originalComposer)
        #expect(pane.composer.draft == originalDraft)
        #expect(pane.readingPosition === originalReadingPosition)
        #expect(pane.readingPosition.mode == originalReadingMode)
        #expect(pane.scrollRequest == originalScrollRequest)

        try pane.reloadTimeline()

        #expect(loadCount == 2)
        #expect(pane.liveStore.state.timeline.turns.map(\.runID) == ["stable-run", "retry-run"])
        #expect(pane.liveStore.state.timeline.turns.filter { $0.runID == "retry-run" }.count == 1)
        #expect(pane.composer.draft == originalDraft)
        #expect(pane.readingPosition.mode == .reading(anchor: anchor, pendingTurns: ["already-pending-run", "retry-run"]))
        let retryRequest = try #require(pane.scrollRequest)
        let previousSequence = originalScrollRequest?.sequence ?? 0
        #expect(retryRequest.sequence > previousSequence)
        #expect(retryRequest.action == .restoreAnchor(anchor))
    }

    @Test
    func streamingDeltaChangesOnlyOwningPane() throws {
        let paneA = try makePane(
            conversationID: "conversation-A",
            turns: [ConversationTurn(runID: "run-A", items: [.userText("prompt A")])]
        )
        let paneB = try makePane(
            conversationID: "conversation-B",
            turns: [ConversationTurn(runID: "run-B", items: [.userText("prompt B")])]
        )
        let originalTimelineB = paneB.liveStore.state.timeline

        _ = try paneA.consume(
            .messagePartStarted(runID: "run-A", messageID: "message-A", partID: "part-A", kind: .text),
            in: "conversation-A"
        )
        _ = try paneA.consume(
            .messagePartDelta(runID: "run-A", partID: "part-A", delta: "A"),
            in: "conversation-A"
        )

        #expect(assistantTexts(in: paneA.liveStore.state.timeline) == ["A"])
        #expect(paneA.liveStore.state.timeline.turns.map(\.runID) == ["run-A"])
        #expect(paneB.liveStore.state.timeline == originalTimelineB)
        #expect(paneB.liveStore.state.activeParts.isEmpty)

        _ = try paneB.consume(
            .messagePartStarted(runID: "run-B", messageID: "message-B", partID: "part-B", kind: .text),
            in: "conversation-B"
        )
        _ = try paneB.consume(
            .messagePartDelta(runID: "run-B", partID: "part-B", delta: "B"),
            in: "conversation-B"
        )

        #expect(assistantTexts(in: paneA.liveStore.state.timeline) == ["A"])
        #expect(assistantTexts(in: paneB.liveStore.state.timeline) == ["B"])
        #expect(Set(paneA.liveStore.state.activeParts.keys) == Set(["part-A"]))
        #expect(Set(paneB.liveStore.state.activeParts.keys) == Set(["part-B"]))
    }

    @Test
    func approvalRefreshKeepsOnlyOwningCardsAndCanRetry() async throws {
        let environment = try makeApprovalEnvironment()
        try makePersistedApproval(
            in: environment.store,
            conversationID: "approval-owner-a",
            runID: "approval-run-a",
            callID: "approval-call-a"
        )
        try makePersistedApproval(
            in: environment.store,
            conversationID: "approval-owner-b",
            runID: "approval-run-b",
            callID: "approval-call-b"
        )
        let runtime = makeProjectionRuntime(for: environment)
        let approvalsA = try await runtime.pendingToolApprovals(in: "approval-owner-a")
        let approvalsB = try await runtime.pendingToolApprovals(in: "approval-owner-b")
        let paneA = try makePane(conversationID: "approval-owner-a")
        let paneB = try makePane(conversationID: "approval-owner-b")
        paneA.liveStore.reconcilePendingToolApprovals(approvalsA)
        paneB.liveStore.reconcilePendingToolApprovals(approvalsB)
        _ = paneA.liveStore.consume(.approvalRequired(
            runID: "approval-run-a",
            toolCallID: "approval-call-a"
        ))

        let failingRuntime = try makeFailingProjectionRuntime()
        var refreshFailed = false
        do {
            try await paneA.refreshPendingApprovals(using: failingRuntime)
        } catch {
            refreshFailed = true
        }

        #expect(refreshFailed)
        #expect(paneA.liveStore.state.pendingToolApprovals.map(\.toolCallID) == ["approval-call-a"])
        #expect(paneA.liveStore.needsPendingToolApprovalReconciliation)
        #expect(paneB.liveStore.state.pendingToolApprovals.map(\.toolCallID) == ["approval-call-b"])
        #expect(!paneB.liveStore.needsPendingToolApprovalReconciliation)

        try environment.store.database.write { db in
            try db.execute(
                sql: "UPDATE toolCall SET state = ?, updatedAt = ? WHERE id = ?",
                arguments: [ToolCallState.succeeded.rawValue, Date(), "approval-call-a"]
            )
        }
        #expect(try environment.store.toolCall(id: "approval-call-a")?.state == .succeeded)

        try await paneA.refreshPendingApprovals(using: runtime)

        #expect(paneA.liveStore.state.pendingToolApprovals.isEmpty)
        #expect(!paneA.liveStore.needsPendingToolApprovalReconciliation)
        #expect(paneB.liveStore.state.pendingToolApprovals.map(\.toolCallID) == ["approval-call-b"])
        #expect(approvalsA.map(\.conversationID) == ["approval-owner-a"])
        #expect(approvalsB.map(\.conversationID) == ["approval-owner-b"])
    }

    private func makePane(
        conversationID: String,
        initialTimeline: ConversationTimelineProjection? = nil,
        turns: [ConversationTurn] = [],
        loadTimeline: (@MainActor (String) throws -> ConversationTimelineProjection)? = nil
    ) throws -> ConversationPaneController {
        let startingTimeline = initialTimeline ?? ConversationTimelineProjection(
            conversationID: conversationID,
            turns: turns
        )
        let resolvedLoader = loadTimeline ?? { requestedConversationID in
            ConversationTimelineProjection(
                conversationID: requestedConversationID,
                turns: turns
            )
        }
        return try ConversationPaneController(
            conversationID: conversationID,
            initialTimeline: startingTimeline,
            configuration: ConversationComposerConfiguration(
                providerInstanceID: ProviderInstanceID(rawValue: "pane-test-provider"),
                modelID: ModelID(rawValue: "pane-test-model")
            ),
            coalescer: StreamingCoalescer(interval: .milliseconds(0)),
            tolerance: 12,
            loadTimeline: resolvedLoader
        )
    }

    private func makeDraft(text: String, selection: Range<Int>) -> ComposerDraftState {
        ComposerDraftState(
            text: text,
            selection: ComposerSelection(range: selection),
            references: [],
            attachments: [],
            presentationState: .editing
        )
    }

    private func makeApproval(toolCallID: String, conversationID: String) -> ToolApprovalProjection {
        ToolApprovalProjection(
            toolCallID: toolCallID,
            conversationID: conversationID,
            runtimeInstanceID: "pane-test-runtime",
            disclosure: ToolApprovalDisclosure(
                toolDisplayName: "Pane test tool",
                action: "Write a test record",
                targetDescription: "Pane \(conversationID)",
                keyImpact: "Only the selected test record changes"
            )
        )
    }

    private func assistantTexts(in timeline: ConversationTimelineProjection) -> [String] {
        timeline.turns.flatMap { turn in
            turn.items.compactMap { item in
                guard case let .assistantText(text) = item else { return nil }
                return text
            }
        }
    }

    private func applying(
        _ action: ScrollAction,
        to geometry: ScrollGeometry,
        turnTops: [String: Double]
    ) -> ScrollGeometry {
        let offset: Double
        switch action {
        case .none:
            offset = geometry.offset
        case .scrollToBottom:
            offset = max(0, geometry.contentHeight - geometry.viewportHeight)
        case .restoreAnchor(let anchor):
            if let turnTop = turnTops[anchor.runID] {
                offset = turnTop - anchor.relativeViewportOffset * geometry.viewportHeight
            } else {
                offset = geometry.offset
            }
        case .maintainBottomEdge(let targetOffset):
            offset = targetOffset
        }
        return ScrollGeometry(
            viewportHeight: geometry.viewportHeight,
            contentHeight: geometry.contentHeight,
            offset: offset
        )
    }

    private func makeApprovalEnvironment() throws -> ConversationPaneApprovalEnvironment {
        ConversationPaneApprovalEnvironment(
            store: PersistenceStore(database: try ZenDatabase.inMemory()),
            credentials: makeCredentialStore()
        )
    }

    private func makeProjectionRuntime(
        for environment: ConversationPaneApprovalEnvironment
    ) -> ConversationRuntime {
        ConversationRuntime(
            store: environment.store,
            provider: FakeProvider(),
            credentials: environment.credentials,
            toolRegistry: ToolRegistry.empty
        )
    }

    private func makeFailingProjectionRuntime() throws -> ConversationRuntime {
        let database = try ZenDatabase.inMemory()
        try database.write { db in
            try db.execute(sql: "DROP TABLE agentRun")
        }
        return ConversationRuntime(
            store: PersistenceStore(database: database),
            provider: FakeProvider(),
            credentials: makeCredentialStore(),
            toolRegistry: ToolRegistry.empty
        )
    }

    private func makeCredentialStore() -> CredentialStore {
        CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: InMemoryCredentialMetadataRepository()
        )
    }

    private func makePersistedApproval(
        in store: PersistenceStore,
        conversationID: String,
        runID: String,
        callID: String
    ) throws {
        let tool = I07RecordingTool(
            id: "pane-approval-probe",
            approvalRequirement: .required,
            ledger: I07ToolLedger()
        )
        var intent = try tool.prepare(callID: callID, argumentsJSON: "{}")
        intent.approvalDisclosure = ToolApprovalDisclosure(
            toolDisplayName: "Pane approval probe",
            action: "Write one isolated record",
            targetDescription: "Conversation \(conversationID)",
            keyImpact: "Only this record is affected"
        )
        _ = try store.commitUserTurnAndCreateParentRun(
            Fixtures.send(
                conversationID: conversationID,
                messageID: "message-\(runID)",
                runID: runID,
                runState: .waitingForApproval
            )
        )
        let encodedIntent = String(decoding: try JSONEncoder().encode(intent), as: UTF8.self)
        try store.createToolCall(Fixtures.toolCall(
            id: callID,
            runID: runID,
            action: intent.toolID,
            state: .waitingForApproval,
            intent: encodedIntent
        ))
    }
}

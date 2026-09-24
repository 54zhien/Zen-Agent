import Testing

@testable import ZenAgent

@Suite("Reusable conversation pane scroll bridge")
@MainActor
struct ConversationPaneScrollBridgeTests {

    @Test
    func readingPaneQueuesAnchorRestoreWhileOtherPaneFollowsBottom() throws {
        let paneA = try makePane(
            conversationID: "scroll-owner-a",
            turns: [ConversationTurn(runID: "scroll-run-a", items: [.userText("A")])]
        )
        let paneB = try makePane(
            conversationID: "scroll-owner-b",
            turns: [ConversationTurn(runID: "scroll-run-b", items: [.userText("B")])]
        )
        let bridgeA = ConversationPaneScrollBridge(pane: paneA)
        let geometryA = ScrollGeometry(viewportHeight: 400, contentHeight: 1_000, offset: 300)
        let anchorA = TurnAnchor(runID: "scroll-run-a", relativeViewportOffset: -0.125)

        bridgeA.userScrolled(
            geometry: geometryA,
            topVisibleTurn: (runID: "scroll-run-a", turnTop: 250)
        )
        #expect(paneA.readingPosition.mode == .reading(anchor: anchorA, pendingTurns: []))
        #expect(paneB.readingPosition.mode == .followingBottom)
        #expect(paneA.readingPosition !== paneB.readingPosition)

        _ = try paneA.consume(
            .messagePartStarted(runID: "scroll-run-a", messageID: "message-a", partID: "part-a", kind: .text),
            in: "scroll-owner-a"
        )
        _ = try paneB.consume(
            .messagePartStarted(runID: "scroll-run-b", messageID: "message-b", partID: "part-b", kind: .text),
            in: "scroll-owner-b"
        )

        let requestA = try #require(paneA.scrollRequest)
        let requestB = try #require(paneB.scrollRequest)
        #expect(requestA.action == .restoreAnchor(anchorA))
        #expect(requestB.action == .scrollToBottom)
        #expect(paneA.readingPosition.mode == .reading(
            anchor: anchorA,
            pendingTurns: ["scroll-run-a"]
        ))
        #expect(paneB.readingPosition.mode == .followingBottom)

        let appliedA = applying(
            requestA.action,
            to: geometryA,
            turnTops: ["scroll-run-a": 250]
        )
        let geometryB = ScrollGeometry(viewportHeight: 300, contentHeight: 1_000, offset: 200)
        let appliedB = applying(requestB.action, to: geometryB, turnTops: [:])
        #expect(appliedA.offset == 300)
        #expect(appliedB.offset == 700)
        _ = paneA.updateReading(.programmaticScrolled(geometry: appliedA))
        paneA.markScrollApplied(sequence: requestA.sequence)
        _ = paneB.updateReading(.programmaticScrolled(geometry: appliedB))
        paneB.markScrollApplied(sequence: requestB.sequence)

        #expect(paneA.scrollRequest == nil)
        #expect(paneB.scrollRequest == nil)
        #expect(paneA.readingPosition.mode == .reading(
            anchor: anchorA,
            pendingTurns: ["scroll-run-a"]
        ))
        #expect(paneB.readingPosition.mode == .followingBottom)
    }

    @Test
    func resizeUsesCapturedBottomEdgeAndRejectsInvalidGeometry() throws {
        let pane = try makePane(
            conversationID: "resize-owner",
            turns: [ConversationTurn(runID: "resize-run", items: [.userText("read here")])]
        )
        let bridge = ConversationPaneScrollBridge(pane: pane)
        let initialGeometry = ScrollGeometry(viewportHeight: 400, contentHeight: 1_200, offset: 300)
        bridge.userScrolled(
            geometry: initialGeometry,
            topVisibleTurn: (runID: "resize-run", turnTop: 250)
        )
        bridge.beginHeightChange(
            geometry: initialGeometry,
            bottomReferenceTurn: (runID: "resize-run", turnTop: 250)
        )

        let firstResize = ScrollGeometry(viewportHeight: 300, contentHeight: 650, offset: 300)
        bridge.continueHeightChange(
            geometry: firstResize,
            turnTops: ["resize-run": 270]
        )
        let firstRequest = try #require(pane.scrollRequest)
        let firstTarget: Double
        if case let .maintainBottomEdge(targetOffset) = firstRequest.action {
            firstTarget = targetOffset
        } else {
            Issue.record("the first valid resize must maintain the captured bottom edge")
            return
        }
        #expect(firstTarget == 350)
        #expect(firstTarget.isFinite)
        #expect(firstTarget >= 0 && firstTarget <= 350)

        let afterFirstResize = applying(firstRequest.action, to: firstResize, turnTops: [:])
        #expect(afterFirstResize.offset == 350)
        _ = pane.updateReading(.programmaticScrolled(geometry: afterFirstResize))
        pane.markScrollApplied(sequence: firstRequest.sequence)

        let secondResize = ScrollGeometry(viewportHeight: 250, contentHeight: 1_200, offset: 350)
        // With offset 350, viewport 250, and Turn top 280, recapturing gives b = 320.
        // Keeping the original b = 450 instead gives target 280 + 450 - 250 = 480.
        bridge.continueHeightChange(
            geometry: secondResize,
            turnTops: ["resize-run": 280]
        )
        let secondRequest = try #require(pane.scrollRequest)
        let secondTarget: Double
        if case let .maintainBottomEdge(targetOffset) = secondRequest.action {
            secondTarget = targetOffset
        } else {
            Issue.record("the second valid resize must keep the original bottom-edge capture")
            return
        }
        #expect(secondTarget == 480)
        #expect(secondTarget.isFinite)
        #expect(secondTarget >= 0 && secondTarget <= 950)

        let afterSecondResize = applying(secondRequest.action, to: secondResize, turnTops: [:])
        #expect(afterSecondResize.offset == 480)
        _ = pane.updateReading(.programmaticScrolled(geometry: afterSecondResize))
        pane.markScrollApplied(sequence: secondRequest.sequence)

        let invalidViewport = ScrollGeometry(viewportHeight: 0, contentHeight: 1_200, offset: 480)
        let modeBeforeInvalidViewport = pane.readingPosition.mode
        bridge.continueHeightChange(
            geometry: invalidViewport,
            turnTops: ["resize-run": 280]
        )
        #expect(pane.scrollRequest == nil)
        #expect(pane.readingPosition.mode == modeBeforeInvalidViewport)

        let invalidContent = ScrollGeometry(viewportHeight: 250, contentHeight: .infinity, offset: 480)
        let modeBeforeInvalidContent = pane.readingPosition.mode
        bridge.continueHeightChange(
            geometry: invalidContent,
            turnTops: ["resize-run": 280]
        )
        #expect(pane.scrollRequest == nil)
        #expect(pane.readingPosition.mode == modeBeforeInvalidContent)
        bridge.endHeightChange()
    }

    @Test
    func userDragSupersedesPendingProgrammaticScroll() throws {
        let pane = try makePane(
            conversationID: "drag-owner",
            turns: [ConversationTurn(runID: "drag-run", items: [.userText("prompt")])]
        )
        let bridge = ConversationPaneScrollBridge(pane: pane)
        let queuedGeometry = ScrollGeometry(viewportHeight: 300, contentHeight: 1_000, offset: 250)
        _ = pane.updateReading(.contentChanged(changedRunIDs: ["arrived-while-following"]))
        let queuedRequest = try #require(pane.scrollRequest)
        #expect(queuedRequest.action == .scrollToBottom)
        let viewport = ScrollViewportFixture(geometry: queuedGeometry)
        #expect(viewport.geometry.offset == 250)
        let obsoleteTarget = applying(queuedRequest.action, to: queuedGeometry, turnTops: [:])
        #expect(obsoleteTarget.offset == 700)

        let draggedGeometry = ScrollGeometry(viewportHeight: 300, contentHeight: 1_000, offset: 500)
        let dragAnchor = TurnAnchor(runID: "drag-run", relativeViewportOffset: -0.1)
        viewport.measureUserDrag(
            draggedGeometry,
            through: bridge,
            topVisibleTurn: (runID: "drag-run", turnTop: 470)
        )

        #expect(pane.scrollRequest == nil)
        #expect(pane.readingPosition.mode == .reading(anchor: dragAnchor, pendingTurns: []))
        #expect(!viewport.apply(queuedRequest, to: pane, turnTops: [:]))
        viewport.deliverReceipt(for: queuedRequest, to: pane)

        #expect(viewport.geometry.offset == 500)
        #expect(pane.scrollRequest == nil)
        #expect(pane.readingPosition.mode == .reading(anchor: dragAnchor, pendingTurns: []))

        _ = pane.updateReading(.contentChanged(changedRunIDs: ["arrived-while-reading"]))
        let replacementRequest = try #require(pane.scrollRequest)
        #expect(replacementRequest.sequence > queuedRequest.sequence)
        #expect(replacementRequest.action == .restoreAnchor(dragAnchor))

        viewport.deliverReceipt(for: queuedRequest, to: pane)
        #expect(pane.scrollRequest?.sequence == replacementRequest.sequence)
        #expect(viewport.geometry.offset == 500)
        #expect(pane.readingPosition.mode == .reading(
            anchor: dragAnchor,
            pendingTurns: ["arrived-while-reading"]
        ))

        #expect(viewport.apply(replacementRequest, to: pane, turnTops: ["drag-run": 470]))
        #expect(viewport.geometry.offset == 500)
        #expect(pane.scrollRequest == nil)
    }

    private func makePane(
        conversationID: String,
        turns: [ConversationTurn] = []
    ) throws -> ConversationPaneController {
        try ConversationPaneController(
            conversationID: conversationID,
            initialTimeline: ConversationTimelineProjection(
                conversationID: conversationID,
                turns: turns
            ),
            configuration: ConversationComposerConfiguration(
                providerInstanceID: ProviderInstanceID(rawValue: "scroll-test-provider"),
                modelID: ModelID(rawValue: "scroll-test-model")
            ),
            coalescer: StreamingCoalescer(interval: .milliseconds(0)),
            tolerance: 12,
            loadTimeline: { requestedConversationID in
                ConversationTimelineProjection(conversationID: requestedConversationID, turns: turns)
            }
        )
    }

}

@MainActor
private final class ScrollViewportFixture {
    private(set) var geometry: ScrollGeometry

    init(geometry: ScrollGeometry) {
        self.geometry = geometry
    }

    func measureUserDrag(
        _ measuredGeometry: ScrollGeometry,
        through bridge: ConversationPaneScrollBridge,
        topVisibleTurn: (runID: String, turnTop: Double)?
    ) {
        geometry = measuredGeometry
        bridge.userScrolled(geometry: measuredGeometry, topVisibleTurn: topVisibleTurn)
    }

    @discardableResult
    func apply(
        _ request: ConversationPaneScrollRequest,
        to pane: ConversationPaneController,
        turnTops: [String: Double]
    ) -> Bool {
        guard pane.scrollRequest?.sequence == request.sequence else { return false }

        let appliedGeometry = applying(request.action, to: geometry, turnTops: turnTops)
        geometry = appliedGeometry
        _ = pane.updateReading(.programmaticScrolled(geometry: appliedGeometry))
        pane.markScrollApplied(sequence: request.sequence)
        return true
    }

    func deliverReceipt(for request: ConversationPaneScrollRequest, to pane: ConversationPaneController) {
        _ = pane.updateReading(.programmaticScrolled(geometry: geometry))
        pane.markScrollApplied(sequence: request.sequence)
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

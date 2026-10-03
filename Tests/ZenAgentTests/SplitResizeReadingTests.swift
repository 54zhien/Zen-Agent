import Testing
@testable import ZenAgent

@Suite("Split resize reading continuity")
struct SplitResizeReadingTests {
    @Test("two streaming Panes keep independent reading and following-bottom positions through repeated resize")
    @MainActor
    func twoStreamingPanesPreserveTheirOwnBottomReferences() throws {
        func pane(_ id: String) throws -> ConversationPaneController {
            let turns = [
                ConversationTurn(runID: "\(id)-old", items: [.userText("earlier")]),
                ConversationTurn(runID: "\(id)-live", items: [.userText("streaming")])
            ]
            return try ConversationPaneController(conversationID: id,
                initialTimeline: ConversationTimelineProjection(conversationID: id, turns: turns),
                configuration: ConversationComposerConfiguration(
                    providerInstanceID: ProviderInstanceID(rawValue: "resize-provider"),
                    modelID: ModelID(rawValue: "resize-model")),
                coalescer: StreamingCoalescer(interval: .milliseconds(0)), tolerance: 12,
                loadTimeline: { requested in
                    ConversationTimelineProjection(conversationID: requested, turns: turns)
                })
        }
        let reading = try pane("reading")
        let following = try pane("following")
        let initial = ScrollGeometry(viewportHeight: 400, contentHeight: 1_800, offset: 200)
        reading.scrollBridge.userScrolled(geometry: initial,
            topVisibleTurn: (runID: "reading-old", turnTop: 100))
        reading.scrollBridge.beginHeightChange(geometry: initial,
            bottomReferenceTurn: (runID: "reading-live", turnTop: 500))
        following.scrollBridge.beginHeightChange(
            geometry: ScrollGeometry(viewportHeight: 400, contentHeight: 1_800, offset: 1_400),
            bottomReferenceTurn: (runID: "following-live", turnTop: 1_700))
        for owner in [reading, following] {
            let id = owner.conversationID
            _ = try owner.consume(.messagePartStarted(runID: "\(id)-live",
                messageID: "\(id)-message", partID: "\(id)-part", kind: .text), in: id)
        }
        var readingOffset = 200.0
        var followingOffset = 1_400.0
        for (index, height) in [340.0, 270.0, 390.0].enumerated() {
            for owner in [reading, following] {
                let id = owner.conversationID
                _ = try owner.consume(.messagePartDelta(runID: "\(id)-live",
                    partID: "\(id)-part", delta: "x", endUTF8Offset: index + 1), in: id)
                owner.flushStreamingText()
            }
            let contentHeight = 1_800.0 + Double(index + 1) * 30
            reading.scrollBridge.continueHeightChange(
                geometry: ScrollGeometry(viewportHeight: height, contentHeight: contentHeight, offset: readingOffset),
                turnTops: ["reading-old": 100, "reading-live": 500])
            following.scrollBridge.continueHeightChange(
                geometry: ScrollGeometry(viewportHeight: 800 - height, contentHeight: contentHeight, offset: followingOffset),
                turnTops: ["following-old": 100, "following-live": 1_700])
            readingOffset = 600 - height
            followingOffset = contentHeight - (800 - height)
            #expect(reading.scrollRequest?.action == .maintainBottomEdge(targetOffset: readingOffset))
            #expect(following.scrollRequest?.action == .maintainBottomEdge(targetOffset: followingOffset))
            #expect(following.readingPosition.mode == .followingBottom)
            #expect(reading.readingPosition.newContentCount == 1)
            if let sequence = reading.scrollRequest?.sequence { reading.markScrollApplied(sequence: sequence) }
            if let sequence = following.scrollRequest?.sequence { following.markScrollApplied(sequence: sequence) }
        }
        reading.scrollBridge.endHeightChange()
        following.scrollBridge.endHeightChange()
    }

    @Test("after resize the saved anchor restores the measured bottom reference Turn, not an unrelated top Turn")
    func differentTopAndBottomTurnsRemainRestorable() throws {
        let machine = ReadingPositionStateMachine(tolerance: 12)
        let initial = ScrollGeometry(viewportHeight: 400, contentHeight: 1_600, offset: 200)
        let bottom = try #require(AnchorResolver.captureBottomAnchor(
            runID: "bottom-reference", turnTop: 500, geometry: initial))
        let before = ReadingMode.reading(
            anchor: TurnAnchor(runID: "top-reference", relativeViewportOffset: -0.25),
            pendingTurns: ["streaming-other"])
        let resized = ScrollGeometry(viewportHeight: 300, contentHeight: 1_650, offset: 200)
        let result = machine.reduce(before, .paneHeightChanged(
            geometry: resized, anchor: bottom, turnTop: 500))
        #expect(result.action == .maintainBottomEdge(targetOffset: 300))

        // A later token update must restore the same position after the resize
        // transaction has ended, even when different Turns touch its two edges.
        let token = machine.reduce(result.mode, .contentChanged(changedRunIDs: ["streaming-other"]))
        guard case .restoreAnchor(let saved) = token.action else {
            Issue.record("Reading must retain a restorable anchor after resize")
            return
        }
        let tops = ["top-reference": 100.0, "bottom-reference": 500.0]
        let measuredTop = try #require(tops[saved.runID])
        let restored = try #require(AnchorResolver.restoreTarget(
            anchor: saved, turnTop: measuredTop, geometry: resized))
        #expect(abs(restored - 300) < 0.001)
        #expect(token.newContentCount == 1)
    }
}

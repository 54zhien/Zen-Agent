import SwiftUI
import Testing
@testable import ZenAgent

@Suite("Timeline native scroll coordinates")
@MainActor
struct ConversationScrollGeometryTests {
    @Test func shortContentDoesNotAcquireAnInsetSizedScrollRange() {
        let raw = SwiftUI.ScrollGeometry(contentOffset: CGPoint(x: 0, y: -116),
            contentSize: CGSize(width: 402, height: 56),
            contentInsets: EdgeInsets(top: 116, leading: 0, bottom: 108, trailing: 0),
            containerSize: CGSize(width: 402, height: 153))
        let geometry = ConversationTimelineView.paneGeometry(from: raw)
        #expect(geometry.viewportHeight == 153)
        #expect(geometry.contentHeight == 56)
        #expect(geometry.offset == 0)
        #expect(max(0, geometry.contentHeight - geometry.viewportHeight) == geometry.offset)
        #expect(BottomDetector.isAtBottom(geometry: geometry, tolerance: 0))
    }

    @Test func actualNativeBottomClearsTheLogicalBottomRequest() {
        let raw = SwiftUI.ScrollGeometry(contentOffset: CGPoint(x: 0, y: 1679),
            contentSize: CGSize(width: 402, height: 2042),
            contentInsets: EdgeInsets(top: 116, leading: 0, bottom: 74, trailing: 0),
            containerSize: CGSize(width: 402, height: 247))
        let geometry = ConversationTimelineView.paneGeometry(from: raw)
        #expect(geometry.viewportHeight == 247)
        #expect(geometry.contentHeight == 2042)
        #expect(geometry.offset == 1795)
        #expect(geometry.distanceFromBottom == 0)
    }

    @Test func remountWaitsForTheTurnMeasurementAtTheNewScrollOffset() throws {
        // Native deep-remount trace: the offset callback preceded its Turn frame.
        let geometry = ZenAgent.ScrollGeometry(viewportHeight: 704, contentHeight: 39683,
                                               offset: 19967.333333333332)
        let contentTop = 20107.999999999993
        #expect(ConversationTimelineView.measuredTurnTop(viewportTop: 143.33333333332484,
            contentTop: contentTop, geometry: geometry) == nil)

        let measuredTop = try #require(ConversationTimelineView.measuredTurnTop(
            viewportTop: 140.6666666666606, contentTop: contentTop, geometry: geometry))
        let target = try #require(AnchorResolver.restoreTarget(
            anchor: TurnAnchor(runID: "reading-turn", relativeViewportOffset: 0.2),
            turnTop: measuredTop, geometry: geometry))
        #expect(abs(target - 19967.2) < 0.000001)
    }

    @Test func aNewTurnMeasurementCannotAcknowledgeAnOlderScrollOffset() {
        let oldGeometry = ZenAgent.ScrollGeometry(viewportHeight: 704, contentHeight: 39707,
                                                  offset: 19964.666666666668)
        #expect(ConversationTimelineView.measuredTurnTop(viewportTop: 140.6666666666606,
            contentTop: 20107.999999999993, geometry: oldGeometry) == nil)
    }

    @Test func materializedAnchorCanRestoreAfterTheFirstAcknowledgmentAndViewportChange() throws {
        // CI 38216654193: the ID jump had already materialized this Turn and
        // seq1 was acknowledged. Its viewport frame stayed at -28 while native
        // geometry returned to the restored offset and the viewport became 704.
        let afterFirstAcknowledgment = ZenAgent.ScrollGeometry(
            viewportHeight: 704, contentHeight: 39707, offset: 19964.666666666668)
        let measuredTop = try #require(ConversationTimelineView.measuredTurnTop(
            viewportTop: -28, contentTop: 20107.999999999993,
            geometry: afterFirstAcknowledgment, usesMaterializedContentCoordinates: true))
        let anchor = TurnAnchor(runID: "reading-turn", relativeViewportOffset: 0.2)
        let target = try #require(AnchorResolver.restoreTarget(
            anchor: anchor, turnTop: measuredTop, geometry: afterFirstAcknowledgment))
        #expect(abs(target - 19967.2) < 0.000001)
        #expect(abs(afterFirstAcknowledgment.offset - target) > 0.5)

        // The offset may converge without another viewport-frame preference.
        let converged = ZenAgent.ScrollGeometry(
            viewportHeight: 704, contentHeight: 39707, offset: 19967.333333333332)
        let convergedTop = try #require(ConversationTimelineView.measuredTurnTop(
            viewportTop: -28, contentTop: 20107.999999999993,
            geometry: converged, usesMaterializedContentCoordinates: true))
        let convergedTarget = try #require(AnchorResolver.restoreTarget(
            anchor: anchor, turnTop: convergedTop, geometry: converged))
        #expect(abs(converged.offset - convergedTarget) <= 0.5)
    }
}

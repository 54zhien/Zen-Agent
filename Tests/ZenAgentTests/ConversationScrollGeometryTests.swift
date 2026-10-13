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

    @Test func freshTurnMeasurementReceivesTheCompletedScrollWithoutAnotherOffsetCallback() throws {
        // Full CI38355408743: this frame and content coordinate agree with the
        // native UIScrollView, but the last offset callback remained at 19964.6667.
        let cached = ZenAgent.ScrollGeometry(viewportHeight: 704, contentHeight: 39707,
                                              offset: 19964.666666666668)
        let observed = try #require(ConversationTimelineView.measuredRestorationGeometry(
            viewportTop: 140.6666666666606, contentTop: 20107.999999999993,
            measuredViewportHeight: 704, geometry: cached))
        #expect(abs(observed.offset - 19967.333333333332) < 0.000001)
    }

    @Test func aFreshViewportCannotAcknowledgeThePreviousViewportTarget() {
        let previousViewport = ZenAgent.ScrollGeometry(viewportHeight: 716, contentHeight: 39707,
                                                        offset: 19964.666666666668)
        #expect(ConversationTimelineView.measuredRestorationGeometry(
            viewportTop: 143.33333333332484, contentTop: 20107.999999999993,
            measuredViewportHeight: 704, geometry: previousViewport) == nil)
    }

    @Test func matchedPositionClearsTheRealRequestAndSurvivesMetadataOnlyReplacement() throws {
        let anchor = TurnAnchor(runID: "reading-turn", relativeViewportOffset: 0.2)
        let pane = try makeReadingPane()
        pane.restoreAnchorForUITest(anchor)
        let request = try #require(pane.scrollRequest)
        let observation = matchedObservation()
        let cached = ZenAgent.ScrollGeometry(viewportHeight: 704, contentHeight: 39707,
                                              offset: observation.nativeOffset)
        let observed = try #require(observation.mergingMetadata(from: cached,
            previousNativeOffset: cached.offset, anchor: anchor, layoutRevision: 7, workspaceRevision: 3))
        let target = try #require(AnchorResolver.restoreTarget(
            anchor: anchor, turnTop: observation.contentTop, geometry: observed))
        #expect(abs(observed.offset - target) <= 0.5)
        _ = pane.updateReading(.programmaticScrolled(geometry: observed))
        pane.markScrollApplied(sequence: request.sequence)
        #expect(pane.scrollRequest == nil)
        #expect(pane.readingPosition.mode == .reading(anchor: anchor, pendingTurns: []))

        // A later content-height callback repeats the producer's old offset.
        let metadata = ZenAgent.ScrollGeometry(viewportHeight: 704, contentHeight: 39680,
                                                offset: cached.offset)
        let merged = try #require(observation.mergingMetadata(from: metadata,
            previousNativeOffset: cached.offset, anchor: anchor, layoutRevision: 7, workspaceRevision: 3))
        #expect(merged.contentHeight == metadata.contentHeight)
        #expect(merged.offset == observed.offset)
        _ = pane.updateReading(.geometryChanged(geometry: merged, anchor: nil))
        let replacement = try #require(pane.scrollRequest)
        #expect(replacement.sequence > request.sequence)
        _ = pane.updateReading(.programmaticScrolled(geometry: merged))
        pane.markScrollApplied(sequence: replacement.sequence)
        pane.markScrollApplied(sequence: request.sequence)
        #expect(pane.scrollRequest == nil)
        #expect(pane.readingPosition.mode == .reading(anchor: anchor, pendingTurns: []))
    }

    @Test func changedNativePositionAlwaysSupersedesTheMatchedObservation() {
        let observation = matchedObservation()
        let next = ZenAgent.ScrollGeometry(viewportHeight: 704, contentHeight: 39707,
                                            offset: observation.nativeOffset + 1.0 / 3.0)
        #expect(observation.mergingMetadata(from: next, previousNativeOffset: observation.nativeOffset,
            anchor: TurnAnchor(runID: observation.runID, relativeViewportOffset: 0.2),
            layoutRevision: 7, workspaceRevision: 3) == nil)
    }

    @Test func anOffsetReceiptBeforeTheTurnMeasurementDoesNotRecreateACompletedRequest() throws {
        let pane = try makeReadingPane()
        let anchor = TurnAnchor(runID: "reading-turn", relativeViewportOffset: 0.2)
        pane.restoreAnchorForUITest(anchor)
        let request = try #require(pane.scrollRequest)
        let actual = matchedObservation().geometry
        _ = pane.updateReading(.programmaticScrolled(geometry: actual))
        pane.markScrollApplied(sequence: request.sequence)
        let laterMeasurement = try #require(ConversationTimelineView.measuredRestorationGeometry(
            viewportTop: 140.6666666666606, contentTop: 20107.999999999993,
            measuredViewportHeight: 704, geometry: actual))
        #expect(laterMeasurement.offset == actual.offset)
        pane.markScrollApplied(sequence: request.sequence)
        #expect(pane.scrollRequest == nil)
        #expect(pane.readingPosition.mode == .reading(anchor: anchor, pendingTurns: []))
    }

    @Test func nonfiniteTurnCoordinatesCannotProduceAnOffsetReceipt() {
        let geometry = matchedObservation().geometry
        #expect(ConversationTimelineView.measuredRestorationGeometry(viewportTop: .nan,
            contentTop: 20108, measuredViewportHeight: 704, geometry: geometry) == nil)
        #expect(ConversationTimelineView.measuredRestorationGeometry(viewportTop: 140.6667,
            contentTop: .infinity, measuredViewportHeight: 704, geometry: geometry) == nil)
        #expect(ConversationTimelineView.measuredRestorationGeometry(viewportTop: 140.6667,
            contentTop: 20108, measuredViewportHeight: .infinity, geometry: geometry) == nil)
    }

    @Test func incomingContentShrinkRevokesTheMatchedPosition() {
        let observation = matchedObservation()
        let shrunken = ZenAgent.ScrollGeometry(viewportHeight: 704,
            contentHeight: observation.nativeOffset + 704, offset: observation.nativeOffset)
        let anchor = TurnAnchor(runID: observation.runID, relativeViewportOffset: 0.2)
        #expect(!observation.isWithinUnclampedBounds(shrunken, anchor: anchor))
        #expect(observation.mergingMetadata(from: shrunken, previousNativeOffset: shrunken.offset,
            anchor: anchor, layoutRevision: 7, workspaceRevision: 3) == nil)
    }

    @Test func postUserPhaseMeasurementKeepsTheOffsetProducersOriginalBaseline() throws {
        let pane = try makeReadingPane()
        let original = TurnAnchor(runID: "reading-turn", relativeViewportOffset: 0.2)
        pane.restoreAnchorForUITest(original)
        let canceled = try #require(pane.scrollRequest)
        let phaseGeometry = matchedObservation().geometry
        let userAnchor = try #require(AnchorResolver.capture(runID: original.runID,
            turnTop: 20107.999999999993, geometry: phaseGeometry))
        _ = pane.updateReading(.userScrolled(geometry: phaseGeometry, anchor: userAnchor))
        pane.markScrollApplied(sequence: canceled.sequence)
        #expect(pane.scrollRequest == nil)

        // Phase context N2 and the callback producer N1 are different sources.
        // A fresh post-idle pair supplies N2 while retaining producer baseline N1.
        let observation = matchedObservation()
        let producer = ZenAgent.ScrollGeometry(viewportHeight: 704, contentHeight: 39680,
                                                offset: observation.nativeOffset)
        let merged = try #require(observation.mergingMetadata(from: producer,
            previousNativeOffset: producer.offset, anchor: userAnchor,
            layoutRevision: 7, workspaceRevision: 3))
        #expect(merged.offset == phaseGeometry.offset)
        _ = pane.updateReading(.geometryChanged(geometry: merged, anchor: nil))
        let request = try #require(pane.scrollRequest)
        let target = try #require(AnchorResolver.restoreTarget(
            anchor: userAnchor, turnTop: observation.contentTop, geometry: merged))
        #expect(abs(target - merged.offset) <= 0.5)
        _ = pane.updateReading(.programmaticScrolled(geometry: merged))
        pane.markScrollApplied(sequence: request.sequence)
        #expect(pane.scrollRequest == nil)
        #expect(pane.readingPosition.mode == .reading(anchor: userAnchor, pendingTurns: []))
    }

    @Test func observationsCannotCrossRunLayoutAttachmentOrViewport() {
        let observation = matchedObservation()
        let native = ZenAgent.ScrollGeometry(viewportHeight: 704, contentHeight: 39707,
                                              offset: observation.nativeOffset)
        let anchor = TurnAnchor(runID: observation.runID, relativeViewportOffset: 0.2)
        #expect(observation.mergingMetadata(from: native, previousNativeOffset: native.offset,
            anchor: TurnAnchor(runID: "other-turn", relativeViewportOffset: 0.2),
            layoutRevision: 7, workspaceRevision: 3) == nil)
        #expect(observation.mergingMetadata(from: native, previousNativeOffset: native.offset,
            anchor: anchor, layoutRevision: 8, workspaceRevision: 3) == nil)
        #expect(observation.mergingMetadata(from: native, previousNativeOffset: native.offset,
            anchor: anchor, layoutRevision: 7, workspaceRevision: 4) == nil)
        let previousViewport = ZenAgent.ScrollGeometry(viewportHeight: 716, contentHeight: 39707,
                                                        offset: native.offset)
        #expect(observation.mergingMetadata(from: previousViewport, previousNativeOffset: native.offset,
            anchor: anchor, layoutRevision: 7, workspaceRevision: 3) == nil)
    }

    private func matchedObservation() -> ConversationMaterializedScrollObservation {
        ConversationMaterializedScrollObservation(runID: "reading-turn", layoutRevision: 7,
            workspaceRevision: 3, nativeOffset: 19964.666666666668,
            contentTop: 20107.999999999993,
            geometry: ZenAgent.ScrollGeometry(viewportHeight: 704, contentHeight: 39707,
                                               offset: 19967.333333333332))
    }

    private func makeReadingPane() throws -> ConversationPaneController {
        try ConversationPaneController(conversationID: "observed-reading",
            initialTimeline: ConversationTimelineProjection(conversationID: "observed-reading",
                turns: [ConversationTurn(runID: "reading-turn", items: [.userText("read")])]),
            configuration: ConversationComposerConfiguration(
                providerInstanceID: ProviderInstanceID(rawValue: "observed-provider"),
                modelID: ModelID(rawValue: "observed-model")),
            coalescer: StreamingCoalescer(interval: .milliseconds(0)), tolerance: 12,
            loadTimeline: { ConversationTimelineProjection(conversationID: $0, turns: []) })
    }
}

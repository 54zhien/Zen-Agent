import Foundation
import Observation

extension ScrollGeometry {
    var isUsableForPane: Bool {
        viewportHeight > 0
            && viewportHeight.isFinite
            && contentHeight >= 0
            && contentHeight.isFinite
            && offset.isFinite
            && distanceFromBottom.isFinite
    }
}

@MainActor
@Observable
final class ConversationPaneScrollBridge {
    unowned let pane: ConversationPaneController
    private(set) var isHeightChangeActive = false
    private var bottomEdgeAnchor: BottomTurnAnchor?
    private var composerHeightChangeActive = false
    private var composerReadingPixelOffset: (runID: String, points: Double)?
    private var heightChangeStartReadingPixelOffset: (runID: String, points: Double)?
    private(set) var dividerLeaseID: UUID?
    private(set) var dividerFinalRevision: UInt64?
    @ObservationIgnored private var dividerAnchor: BottomTurnAnchor?
    @ObservationIgnored private var dividerStartMode: ReadingMode?
    @ObservationIgnored private var snapshot: (geometry: ScrollGeometry, bottom: (runID: String, turnTop: Double)?)?
    @ObservationIgnored private var dividerCompletion: (@MainActor (UUID) -> Void)?
    @ObservationIgnored private var lastDividerTarget: Double?
    @ObservationIgnored private var preparedDividerRevision: UInt64?
    @ObservationIgnored private var returnLayout: (id: UUID, revision: UInt64, visibility: UInt64,
        completion: @MainActor (UUID) -> Void, invalidation: @MainActor (UUID) -> Void)?

    func awaitReturnLayout(id: UUID, revision: UInt64, visibilityRevision: UInt64,
                           onInvalidation: @escaping @MainActor (UUID) -> Void,
                           completion: @escaping @MainActor (UUID) -> Void) {
        returnLayout = (id, revision, visibilityRevision, completion, onInvalidation)
    }

    func cancelReturnLayout(id: UUID) { if returnLayout?.id == id { returnLayout = nil } }

    func publishReturnLayout(revision: UInt64, visibilityRevision: UInt64, geometry: ScrollGeometry) {
        guard let waiting = returnLayout else { return }
        guard waiting.visibility == visibilityRevision else {
            returnLayout = nil
            waiting.invalidation(waiting.id)
            return
        }
        guard waiting.revision == revision, geometry.isUsableForPane,
              pane.scrollRequest == nil else { return }
        returnLayout = nil
        waiting.completion(waiting.id)
    }

    var hasDividerLease: Bool { dividerLeaseID != nil }

#if DEBUG
    @ObservationIgnored var timelineReceiptDiagnostic = "unmeasured"
    @ObservationIgnored var blankTapDiagnostic = "none"
    @ObservationIgnored var blankTapSequence: UInt64 = 0
    @ObservationIgnored var observedLayoutDiagnostic = "unobserved"
    @ObservationIgnored var nativeGeometryDiagnostic = "unmeasured"
    var dividerDiagnostic: String {
        "\(timelineReceiptDiagnostic);geometry=\(nativeGeometryDiagnostic);observed=\(observedLayoutDiagnostic);blankTapSequence=\(blankTapSequence);blankTap=\(blankTapDiagnostic);lease=\(hasDividerLease);final=\(String(describing: dividerFinalRevision));prepared=\(String(describing: preparedDividerRevision));target=\(String(describing: lastDividerTarget));offset=\(String(describing: snapshot?.geometry.offset));request=\(String(describing: pane.scrollRequest));mode=\(String(describing: pane.readingPosition.mode))"
    }
#endif

    var dividerReferenceTurnID: String? {
        guard hasDividerLease else { return nil }
        if composerHeightChangeActive, let captured = composerReadingPixelOffset { return captured.runID }
        if case .followingBottom = pane.readingPosition.mode { return nil }
        return dividerAnchor?.runID
    }

    func publishViewport(_ geometry: ScrollGeometry, bottomReferenceTurn: (runID: String, turnTop: Double)?) {
        guard geometry.isUsableForPane else { return }
        snapshot = (geometry, bottomReferenceTurn)
    }

    func beginDividerResize(id: UUID, onComplete: @escaping @MainActor (UUID) -> Void) -> Bool {
        guard !hasDividerLease, let snapshot else { return false }
        dividerAnchor = snapshot.bottom.flatMap {
            AnchorResolver.captureBottomAnchor(runID: $0.runID, turnTop: $0.turnTop, geometry: snapshot.geometry)
        }
        if case .reading = pane.readingPosition.mode, dividerAnchor == nil { return false }
        endHeightChange()
        dividerStartMode = pane.readingPosition.mode
        dividerLeaseID = id
        dividerFinalRevision = nil
        dividerCompletion = onComplete
        lastDividerTarget = nil
        preparedDividerRevision = nil
        return true
    }

    func finishDividerResize(id: UUID, revision: UInt64) {
        guard dividerLeaseID == id else { return }
        dividerFinalRevision = revision
    }

    func continueDividerResize(geometry: ScrollGeometry, turnTops: [String: Double], revision: UInt64 = 0) {
        guard hasDividerLease, geometry.isUsableForPane else { return }
        // Each completion needs a target prepared from this layout's reference,
        // even when its numerical offset happens to equal an older target.
        preparedDividerRevision = nil
        if composerHeightChangeActive, let captured = composerReadingPixelOffset {
            guard let turnTop = turnTops[captured.runID], turnTop.isFinite else { return }
            preparedDividerRevision = revision
            let target = min(max(0, geometry.contentHeight - geometry.viewportHeight), max(0, turnTop - captured.points))
            let anchor = TurnAnchor(runID: captured.runID, relativeViewportOffset: captured.points / geometry.viewportHeight)
            if lastDividerTarget == target, pane.scrollRequest?.action == .restoreAnchor(anchor) { return }
            if lastDividerTarget == target,
               pane.scrollRequest == nil && abs(geometry.offset - target) <= 0.5 { return }
            lastDividerTarget = target
            _ = pane.updateReading(.composerHeightChanged(geometry: geometry,
                anchor: anchor))
            return
        }
        let top = dividerAnchor.flatMap { turnTops[$0.runID] }
        let target: Double
        if case .followingBottom = pane.readingPosition.mode {
            target = max(0, geometry.contentHeight - geometry.viewportHeight)
        } else if let dividerAnchor, let top,
                  let restored = AnchorResolver.restoreTargetFromBottomAnchor(anchor: dividerAnchor,
                    turnTop: top, contentHeight: geometry.contentHeight, viewportHeight: geometry.viewportHeight) {
            target = min(max(0, geometry.contentHeight - geometry.viewportHeight), max(0, restored))
        } else { return }
        preparedDividerRevision = revision
        // A scroll callback at the same target must not continuously enqueue a
        // fresh sequence; the final native acknowledgement owns completion.
        if lastDividerTarget == target,
           pane.scrollRequest?.action == .maintainBottomEdge(targetOffset: target) { return }
        if lastDividerTarget == target, pane.scrollRequest == nil,
           abs(geometry.offset - target) <= 0.5 { return }
        lastDividerTarget = target
        _ = pane.updateReading(.paneHeightChanged(geometry: geometry, anchor: dividerAnchor, turnTop: top))
    }

    func acknowledgeDividerResize(revision: UInt64, geometry: ScrollGeometry) {
        guard let id = dividerLeaseID, dividerFinalRevision == revision, preparedDividerRevision == revision,
              pane.scrollRequest == nil, let target = lastDividerTarget,
              abs(geometry.offset - target) <= 0.5 else { return }
        let completion = dividerCompletion
        invalidateDividerResize(id: id)
        completion?(id)
    }

    func invalidateDividerResize(id: UUID) {
        guard dividerLeaseID == id else { return }
        dividerLeaseID = nil
        dividerFinalRevision = nil
        dividerAnchor = nil
        dividerCompletion = nil
        lastDividerTarget = nil
        preparedDividerRevision = nil
        dividerStartMode = nil
    }

    func cancelDividerForPresentationChange(id: UUID) {
        guard dividerLeaseID == id else { return }
        let original = dividerStartMode
        invalidateDividerResize(id: id)
        endHeightChange()
        if let original { pane.restoreInterruptedLayout(original) }
    }

    init(pane: ConversationPaneController) {
        self.pane = pane
    }

    func userScrolled(
        geometry: ScrollGeometry,
        topVisibleTurn: (runID: String, turnTop: Double)?
    ) {
        guard !hasDividerLease else { return }
        endHeightChange()
        let anchor = topVisibleTurn.flatMap { turn -> TurnAnchor? in
            guard geometry.isUsableForPane,
                  turn.turnTop.isFinite,
                  let captured = AnchorResolver.capture(
                    runID: turn.runID,
                    turnTop: turn.turnTop,
                    geometry: geometry
                  ),
                  captured.relativeViewportOffset.isFinite
            else { return nil }
            return captured
        }
        _ = pane.updateReading(.userScrolled(geometry: geometry, anchor: anchor))
    }

    func beginHeightChange(
        geometry: ScrollGeometry,
        bottomReferenceTurn: (runID: String, turnTop: Double)?
    ) {
        guard !isHeightChangeActive,
              geometry.isUsableForPane
        else { return }
        isHeightChangeActive = true
        heightChangeStartReadingPixelOffset = readingPixelOffset(for: geometry)
        if composerHeightChangeActive {
            composerReadingPixelOffset = heightChangeStartReadingPixelOffset
            bottomEdgeAnchor = nil
        } else {
            composerReadingPixelOffset = nil
            bottomEdgeAnchor = bottomReferenceTurn.flatMap { turn in
                guard geometry.isUsableForPane,
                      turn.turnTop.isFinite
                else { return nil }
                return AnchorResolver.captureBottomAnchor(
                    runID: turn.runID,
                    turnTop: turn.turnTop,
                    geometry: geometry
                )
            }
        }
    }

    func continueHeightChange(
        geometry: ScrollGeometry,
        turnTops: [String: Double]
    ) {
        guard isHeightChangeActive,
              geometry.isUsableForPane
        else { return }

        if composerHeightChangeActive {
            let anchor = composerReadingPixelOffset.flatMap { captured -> TurnAnchor? in
                guard geometry.viewportHeight > 0,
                      geometry.viewportHeight.isFinite else { return nil }
                let relativeOffset = captured.points / geometry.viewportHeight
                guard relativeOffset.isFinite else { return nil }
                return TurnAnchor(runID: captured.runID, relativeViewportOffset: relativeOffset)
            }
            _ = pane.updateReading(.composerHeightChanged(geometry: geometry, anchor: anchor))
            return
        }

        let turnTop = bottomEdgeAnchor.flatMap { anchor -> Double? in
            guard let measuredTop = turnTops[anchor.runID],
                  measuredTop.isFinite
            else { return nil }
            return measuredTop
        }
        _ = pane.updateReading(.paneHeightChanged(
            geometry: geometry,
            anchor: bottomEdgeAnchor,
            turnTop: turnTop
        ))
    }

    func composerHeightWillChange() {
        markComposerHeightChange()
    }

    func composerKeyboardWillChange() {
        markComposerHeightChange()
    }

    private func markComposerHeightChange() {
        composerHeightChangeActive = true
        if hasDividerLease {
            composerReadingPixelOffset = snapshot.flatMap { readingPixelOffset(for: $0.geometry) }
            return
        }
        guard isHeightChangeActive else { return }
        composerReadingPixelOffset = heightChangeStartReadingPixelOffset
        bottomEdgeAnchor = nil
    }

    func endHeightChange() {
        isHeightChangeActive = false
        bottomEdgeAnchor = nil
        composerHeightChangeActive = false
        composerReadingPixelOffset = nil
        heightChangeStartReadingPixelOffset = nil
    }

    private func readingPixelOffset(for geometry: ScrollGeometry) -> (runID: String, points: Double)? {
        guard geometry.isUsableForPane,
              case let .reading(anchor, _) = pane.readingPosition.mode,
              anchor.relativeViewportOffset.isFinite else { return nil }
        let points = anchor.relativeViewportOffset * geometry.viewportHeight
        guard points.isFinite else { return nil }
        return (runID: anchor.runID, points: points)
    }
}

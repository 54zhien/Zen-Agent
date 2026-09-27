import Foundation

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
final class ConversationPaneScrollBridge {
    unowned let pane: ConversationPaneController
    private(set) var isHeightChangeActive = false
    private var bottomEdgeAnchor: BottomTurnAnchor?
    private var composerHeightChangeActive = false
    private var composerReadingPixelOffset: (runID: String, points: Double)?

    init(pane: ConversationPaneController) {
        self.pane = pane
    }

    func userScrolled(
        geometry: ScrollGeometry,
        topVisibleTurn: (runID: String, turnTop: Double)?
    ) {
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
        if composerHeightChangeActive {
            composerReadingPixelOffset = readingPixelOffset(for: geometry)
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
        guard !composerHeightChangeActive else { return }
        composerHeightChangeActive = true
    }

    func endHeightChange() {
        isHeightChangeActive = false
        bottomEdgeAnchor = nil
        composerHeightChangeActive = false
        composerReadingPixelOffset = nil
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

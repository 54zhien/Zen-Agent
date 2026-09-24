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

    func continueHeightChange(
        geometry: ScrollGeometry,
        turnTops: [String: Double]
    ) {
        guard isHeightChangeActive,
              geometry.isUsableForPane
        else { return }

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

    func endHeightChange() {
        isHeightChangeActive = false
        bottomEdgeAnchor = nil
    }
}

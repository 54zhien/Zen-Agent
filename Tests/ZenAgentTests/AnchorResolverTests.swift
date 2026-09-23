import Testing

@testable import ZenAgent

@Suite("Turn anchor resolver")
struct AnchorResolverTests {
    @Test("captureThenRestoreReproducesOffsetWhenGeometryIsUnchanged")
    func captureThenRestoreReproducesOffsetWhenGeometryIsUnchanged() {
        let geometry = ScrollGeometry(viewportHeight: 240, contentHeight: 1_200, offset: 510)
        let captured = AnchorResolver.capture(runID: "r1", turnTop: 450, geometry: geometry)

        #expect(captured != nil)
        guard let captured else { return }

        let restored = AnchorResolver.restoreTarget(anchor: captured, turnTop: 450, geometry: geometry)
        #expect(restored != nil)
        guard let restored else { return }
        #expect(abs(restored - geometry.offset) < 1e-9)
    }

    @Test("restoreKeepsRelativeViewportOffsetWhenGeometryChanges")
    func restoreKeepsRelativeViewportOffsetWhenGeometryChanges() {
        let originalGeometry = ScrollGeometry(viewportHeight: 240, contentHeight: 1_200, offset: 510)
        let anchor = AnchorResolver.capture(runID: "r1", turnTop: 450, geometry: originalGeometry)

        #expect(anchor != nil)
        guard let anchor else { return }

        let newGeometry = ScrollGeometry(viewportHeight: 320, contentHeight: 1_600, offset: 0)
        let target = AnchorResolver.restoreTarget(anchor: anchor, turnTop: 450, geometry: newGeometry)

        #expect(target != nil)
        guard let target else { return }
        #expect(abs((450 - target) / newGeometry.viewportHeight - anchor.relativeViewportOffset) < 1e-9)
    }

    @Test("missingAnchoredTurnFallsBackToBottom")
    func missingAnchoredTurnFallsBackToBottom() {
        let anchor = TurnAnchor(runID: "r1", relativeViewportOffset: 0.5)

        #expect(AnchorResolver.resolve(anchor: anchor, presentRunIDs: ["r2"]) == .fallbackToBottom)
        #expect(AnchorResolver.resolve(anchor: anchor, presentRunIDs: ["r1", "r2"]) == .restore(anchor))
    }

    @Test("turnIdentityIsTheRunID")
    func turnIdentityIsTheRunID() {
        let captured = AnchorResolver.capture(
            runID: "run-identity",
            turnTop: 80,
            geometry: ScrollGeometry(viewportHeight: 200, contentHeight: 800, offset: 20)
        )
        let turn = ConversationTurn(runID: "run-identity", items: [])

        #expect(captured?.runID == "run-identity")
        #expect(turn.id == turn.runID)
    }

    @Test("invalidViewportHeightYieldsNoAnchor")
    func invalidViewportHeightYieldsNoAnchor() {
        let zeroGeometry = ScrollGeometry(viewportHeight: 0, contentHeight: 800, offset: 20)
        let negativeGeometry = ScrollGeometry(viewportHeight: -1, contentHeight: 800, offset: 20)
        let anchor = TurnAnchor(runID: "r1", relativeViewportOffset: 0.5)

        #expect(!zeroGeometry.isUsableForAnchor)
        #expect(AnchorResolver.capture(runID: "r1", turnTop: 80, geometry: zeroGeometry) == nil)
        #expect(AnchorResolver.restoreTarget(anchor: anchor, turnTop: 80, geometry: zeroGeometry) == nil)
        #expect(!negativeGeometry.isUsableForAnchor)
        #expect(AnchorResolver.capture(runID: "r1", turnTop: 80, geometry: negativeGeometry) == nil)
        #expect(AnchorResolver.restoreTarget(anchor: anchor, turnTop: 80, geometry: negativeGeometry) == nil)
    }
}

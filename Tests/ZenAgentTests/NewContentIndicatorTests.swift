import Testing

@testable import ZenAgent

@Suite("New content indicator")
struct NewContentIndicatorTests {
    private let anchor = TurnAnchor(runID: "r1", relativeViewportOffset: -0.25)

    @Test("capsuleIsVisibleWhileReadingWithPendingTurns")
    func capsuleIsVisibleWhileReadingWithPendingTurns() {
        let withPending = ReadingMode.reading(anchor: anchor, pendingTurns: ["r2"])
        let withoutPending = ReadingMode.reading(anchor: anchor, pendingTurns: [])

        #expect(NewContentIndicator.isVisible(mode: withPending))
        #expect(NewContentIndicator.count(mode: withPending) == 1)
        #expect(!NewContentIndicator.isVisible(mode: withoutPending))
        #expect(NewContentIndicator.count(mode: withoutPending) == 0)
    }

    @Test("capsuleIsHiddenWhileFollowingBottom")
    func capsuleIsHiddenWhileFollowingBottom() {
        #expect(!NewContentIndicator.isVisible(mode: .followingBottom))
        #expect(NewContentIndicator.count(mode: .followingBottom) == 0)
    }

    @Test("countCountsTurnsNotDeltas")
    func countCountsTurnsNotDeltas() {
        let machine = ReadingPositionStateMachine(tolerance: 12)
        let geometry = ScrollGeometry(viewportHeight: 100, contentHeight: 1_000, offset: 200)
        let anchor = TurnAnchor(runID: "r1", relativeViewportOffset: -0.25)

        let reading = machine.reduce(
            .followingBottom,
            .userScrolled(geometry: geometry, anchor: anchor)
        ).mode
        let afterFirstDelta = machine.reduce(
            reading,
            .contentChanged(changedRunIDs: ["r2"])
        ).mode
        let afterSameTurnDelta = machine.reduce(
            afterFirstDelta,
            .contentChanged(changedRunIDs: ["r2"])
        ).mode
        let afterSecondTurn = machine.reduce(
            afterSameTurnDelta,
            .contentChanged(changedRunIDs: ["r3"])
        ).mode

        #expect(NewContentIndicator.count(mode: afterSameTurnDelta) == 1)
        #expect(NewContentIndicator.count(mode: afterSecondTurn) == 2)
    }
}

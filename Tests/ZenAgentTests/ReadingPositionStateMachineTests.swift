import Testing

@testable import ZenAgent

@Suite("Reading position state machine")
struct ReadingPositionStateMachineTests {
    private let machine = ReadingPositionStateMachine(tolerance: 12)
    private let awayFromBottom = ScrollGeometry(viewportHeight: 100, contentHeight: 1_000, offset: 200)
    private let anchor = TurnAnchor(runID: "r1", relativeViewportOffset: -0.25)

    @Test("atBottomKeepsFollowingBottomOnNewContent")
    func atBottomKeepsFollowingBottomOnNewContent() {
        let output = machine.reduce(
            .followingBottom,
            .contentChanged(changedRunIDs: ["r2"])
        )

        #expect(output.mode == .followingBottom)
        #expect(output.action == .scrollToBottom)
    }

    @Test("readingKeepsAnchorAndAccumulatesPendingOnNewContent")
    func readingKeepsAnchorAndAccumulatesPendingOnNewContent() {
        let output = machine.reduce(
            .reading(anchor: anchor, pendingTurns: []),
            .contentChanged(changedRunIDs: ["r2"])
        )

        #expect(output.mode == .reading(anchor: anchor, pendingTurns: ["r2"]))
        #expect(output.action == .restoreAnchor(anchor))
    }

    @Test("userScrollingUpLeavesFollowingBottom")
    func userScrollingUpLeavesFollowingBottom() {
        let output = machine.reduce(
            .followingBottom,
            .userScrolled(geometry: awayFromBottom, anchor: anchor)
        )

        #expect(output.mode == .reading(anchor: anchor, pendingTurns: []))
    }

    @Test("programmaticScrollDoesNotChangeMode")
    func programmaticScrollDoesNotChangeMode() {
        let following = machine.reduce(
            .followingBottom,
            .programmaticScrolled(geometry: awayFromBottom)
        )
        let reading = machine.reduce(
            .reading(anchor: anchor, pendingTurns: ["r2"]),
            .programmaticScrolled(geometry: awayFromBottom)
        )

        #expect(following.mode == .followingBottom)
        #expect(reading.mode == .reading(anchor: anchor, pendingTurns: ["r2"]))
    }

    @Test("withinToleranceStillCountsAsBottom")
    func withinToleranceStillCountsAsBottom() {
        let exactlyAtTolerance = ScrollGeometry(viewportHeight: 100, contentHeight: 500, offset: 388)
        let justWithinTolerance = ScrollGeometry(viewportHeight: 100, contentHeight: 500, offset: 388.001)
        let justBeyondTolerance = ScrollGeometry(viewportHeight: 100, contentHeight: 500, offset: 387.999)

        #expect(BottomDetector.isAtBottom(geometry: exactlyAtTolerance, tolerance: 12))
        #expect(BottomDetector.isAtBottom(geometry: justWithinTolerance, tolerance: 12))
        #expect(!BottomDetector.isAtBottom(geometry: justBeyondTolerance, tolerance: 12))
    }

    @Test("tappingCapsuleClearsPendingAndReturnsToBottom")
    func tappingCapsuleClearsPendingAndReturnsToBottom() {
        let output = machine.reduce(
            .reading(anchor: anchor, pendingTurns: ["r2", "r3"]),
            .tappedNewContent
        )

        #expect(output.mode == .followingBottom)
        #expect(output.action == .scrollToBottom)
        #expect(output.newContentCount == 0)
        #expect(!output.showsNewContentCapsule)
    }
}

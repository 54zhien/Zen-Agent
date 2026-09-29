import CoreGraphics
import Testing

@testable import ZenAgent

@Suite("App Space upward Delete gesture")
struct AppSpaceCardDeletionGestureTests {
    @Test("only a finite upward direction may capture the Current Card")
    func directionLock() {
        #expect(AppSpaceCardDeletionGesture.shouldBegin(velocity: CGPoint(x: 20, y: -400)))
        #expect(!AppSpaceCardDeletionGesture.shouldBegin(velocity: CGPoint(x: 400, y: -20)))
        #expect(!AppSpaceCardDeletionGesture.shouldBegin(velocity: CGPoint(x: 0, y: 400)))
        #expect(!AppSpaceCardDeletionGesture.shouldBegin(velocity: CGPoint(x: CGFloat.nan, y: -400)))
    }

    @Test("short releases rebound; distance or bounded fling commits Delete")
    func settlementThreshold() {
        let height = 700.0
        #expect(!AppSpaceCardDeletionGesture.shouldDelete(
            translation: CGPoint(x: 0, y: -70), velocity: CGPoint(x: 0, y: -100), height: height))
        #expect(AppSpaceCardDeletionGesture.shouldDelete(
            translation: CGPoint(x: 0, y: -250), velocity: CGPoint(x: 0, y: 0), height: height))
        #expect(AppSpaceCardDeletionGesture.shouldDelete(
            translation: CGPoint(x: 0, y: -70), velocity: CGPoint(x: 0, y: -1_200), height: height))
        #expect(!AppSpaceCardDeletionGesture.shouldDelete(
            translation: CGPoint(x: 0, y: -2), velocity: CGPoint(x: 0, y: -20_000), height: height))
        #expect(!AppSpaceCardDeletionGesture.shouldDelete(
            translation: CGPoint(x: 200, y: -250), velocity: CGPoint(x: 0, y: -1_200), height: height))
        #expect(!AppSpaceCardDeletionGesture.shouldDelete(
            translation: CGPoint(x: 0, y: -250), velocity: CGPoint(x: 0, y: 0), height: .nan))
    }
}

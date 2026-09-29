import CoreGraphics

enum AppSpaceCardDeletionGesture {
    // Runnable seam for native gesture acceptance tests.
    static func shouldBegin(velocity: CGPoint) -> Bool { false }
    static func shouldDelete(translation: CGPoint, velocity: CGPoint, height: Double) -> Bool { false }
}

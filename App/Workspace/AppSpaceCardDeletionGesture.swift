import CoreGraphics

enum AppSpaceCardDeletionGesture {
    static func shouldBegin(velocity: CGPoint) -> Bool {
        velocity.x.isFinite && velocity.y.isFinite && velocity.y < 0
            && -velocity.y > abs(velocity.x) * 1.3
    }

    static func shouldDelete(translation: CGPoint, velocity: CGPoint, height: Double) -> Bool {
        guard height.isFinite, height > 0,
              translation.x.isFinite, translation.y.isFinite,
              velocity.x.isFinite, velocity.y.isFinite,
              translation.y < 0, -translation.y > abs(translation.x) * 1.5 else { return false }
        let distance = Double(-translation.y)
        return distance >= height * 0.28
            || (distance >= height * 0.08 && velocity.y <= -900
                && -velocity.y > abs(velocity.x) * 1.3)
    }
}

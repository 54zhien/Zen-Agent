import Foundation

/// Offsets and velocity are measured in card intervals, independent of refresh rate.
struct AppSpaceBrowseMotion {
    private(set) var offset: Double
    private(set) var velocity: Double
    private(set) var target: Double?
    private(set) var isFinished = false
    private static let friction = 5.5

    init(offset: Double, velocity: Double) {
        self.offset = offset
        self.velocity = velocity
        target = abs(velocity) <= 0.2 ? offset.rounded() : nil
    }

    var destinationWithoutAnimation: Double {
        target ?? (offset + velocity / Self.friction).rounded()
    }

    mutating func advance(deltaTime: Double) {
        guard !isFinished, deltaTime.isFinite, deltaTime > 0 else { return }
        if let target {
            let frequency = 20.0
            let distance = offset - target
            let transport = velocity + frequency * distance
            let decay = exp(-frequency * deltaTime)
            offset = target + (distance + transport * deltaTime) * decay
            velocity = (velocity - frequency * transport * deltaTime) * decay
            if abs(offset - target) < 0.0005 && abs(velocity) < 0.005 {
                offset = target
                velocity = 0
                isFinished = true
            }
        } else {
            let decay = exp(-Self.friction * deltaTime)
            offset += velocity * (1 - decay) / Self.friction
            velocity *= decay
            if abs(velocity) <= 0.2 { target = offset.rounded() }
        }
    }

    mutating func rebase(by intervals: Double) {
        offset -= intervals
        target = target.map { $0 - intervals }
    }

    mutating func snap(to destination: Double) {
        target = destination
        isFinished = false
    }

    mutating func returnFromBoundary(offset: Double) {
        self.offset = offset
        velocity = 0
        snap(to: 0)
    }
}

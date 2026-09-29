import UIKit

enum SplitDropSlot: String, Equatable, Sendable {
    case top
    case bottom
}

struct SplitDropIntent: Equatable, Sendable {
    let conversationID: String
    let slot: SplitDropSlot
}

struct SplitTargetingState {
    struct Update: Equatable {
        let slot: SplitDropSlot?
        let enteredTarget: Bool
    }

    private(set) var slot: SplitDropSlot?

    mutating func update(point: CGPoint, viewport: CGRect, liftProgress: Double) -> Update {
        guard point.x.isFinite, point.y.isFinite,
              viewport.minX.isFinite, viewport.minY.isFinite,
              viewport.width.isFinite, viewport.height.isFinite,
              viewport.width > 0, viewport.height > 0,
              liftProgress.isFinite, liftProgress >= 0.5,
              viewport.contains(point) else {
            slot = nil
            return Update(slot: nil, enteredTarget: false)
        }
        let midpoint = viewport.midY
        // The quiet center band lets Card Lift remain a distinct gesture.
        let band = viewport.height * 0.04
        let next: SplitDropSlot? = point.y < midpoint - band ? .top
            : point.y > midpoint + band ? .bottom : nil
        let entered = next != nil && next != slot
        slot = next
        return Update(slot: next, enteredTarget: entered)
    }

    mutating func end(cancelled: Bool) -> SplitDropSlot? {
        let result = cancelled ? nil : slot
        slot = nil
        return result
    }

    mutating func reset() { slot = nil }
}

enum SplitTargetingGeometry {
    struct Preview: Equatable {
        let pose: SurfaceGeometry.Pose
        let paneFrame: CGRect
        let guideFrame: CGRect
    }

    static func preview(slot: SplitDropSlot, progress: CGFloat,
                        size: CGSize, safeArea: UIEdgeInsets) -> Preview? {
        guard progress.isFinite, progress >= 0, progress <= 1,
              SurfaceGeometry.resolve(size: size, safeArea: safeArea, request: .full) != nil else { return nil }
        let safe = CGRect(x: safeArea.left, y: safeArea.top,
                          width: size.width - safeArea.left - safeArea.right,
                          height: size.height - safeArea.top - safeArea.bottom)
        let gap: CGFloat = 8
        guard safe.width >= 120, safe.height >= 2 * 150 + gap else { return nil }
        let paneHeight = (safe.height - gap) / 2
        let pane = CGRect(x: safe.minX,
            y: slot == .top ? safe.minY : safe.maxY - paneHeight,
            width: safe.width, height: paneHeight)
        let guide = CGRect(x: safe.minX, y: safe.midY - 1,
                           width: safe.width, height: 2)
        guard let destination = SurfaceLiftGeometry.targetPose(size: size, safeArea: safeArea,
            card: pane, cornerRadius: min(22, paneHeight / 2)) else { return nil }
        func between(_ start: CGFloat, _ end: CGFloat) -> CGFloat {
            start + (end - start) * progress
        }
        var pose = SurfaceGeometry.Pose(scale: between(1, destination.scale),
            translation: CGSize(width: destination.translation.width * progress,
                                height: destination.translation.height * progress),
            cornerRadius: destination.cornerRadius * progress)
        pose.clipFraction = CGSize(width: between(1, destination.clipFraction.width),
                                   height: between(1, destination.clipFraction.height))
        return pose.isValid ? Preview(pose: pose, paneFrame: pane, guideFrame: guide) : nil
    }
}

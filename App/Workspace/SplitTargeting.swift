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
        // Fill only near each half's center. Crossing the divider or brushing
        // a display edge must leave the compact Card under finger control.
        let width = viewport.width * 0.6
        let height = viewport.height * 0.1
        func target(centerY: CGFloat) -> CGRect {
            CGRect(x: viewport.midX - width / 2, y: centerY - height / 2, width: width, height: height)
        }
        let next: SplitDropSlot? = target(centerY: viewport.minY + viewport.height * 0.25).contains(point) ? .top
            : target(centerY: viewport.minY + viewport.height * 0.75).contains(point) ? .bottom : nil
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

    /// The divider-facing radius shared with the committed Split Panes.
    static let paneCornerRadius: CGFloat = 24

    /// The preview is the committed Pane itself: the same full-bleed frame and
    /// inner radius `SplitWorkspaceGeometry` produces once the drop converges.
    /// Its exterior corners therefore meet the display's own rounded corners.
    static func preview(slot: SplitDropSlot, progress: CGFloat,
                        size: CGSize, safeArea: UIEdgeInsets) -> Preview? {
        guard progress.isFinite, progress >= 0, progress <= 1,
              SurfaceGeometry.resolve(size: size, safeArea: safeArea, request: .full) != nil,
              size.width >= 120, size.height >= 2 * 150 + 12,
              let layout = SplitWorkspaceGeometry(viewport: CGRect(origin: .zero, size: size), ratio: 0.5)
        else { return nil }
        let pane = layout.frame(for: slot)
        let guide = CGRect(x: layout.divider.minX, y: layout.divider.midY - 1,
                           width: layout.divider.width, height: 2)
        guard let destination = SurfaceLiftGeometry.targetPose(size: size, safeArea: safeArea,
            card: pane, cornerRadius: min(paneCornerRadius, pane.height / 2),
            constrainedToSafeArea: false) else { return nil }
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

import UIKit

enum SurfaceLiftGeometry {
    /// Interactive transport follows the finger; destination geometry is only
    /// used after release. Uniform scale keeps the complete live page visible.
    static func interactivePose(size: CGSize, safeArea: UIEdgeInsets,
                                displacement: CGSize, progress: Double,
                                windowCornerRadius: CGFloat) -> SurfaceGeometry.Pose? {
        let available = CGSize(width: size.width - safeArea.left - safeArea.right,
                               height: size.height - safeArea.top - safeArea.bottom)
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              [safeArea.top, safeArea.left, safeArea.bottom, safeArea.right]
                .allSatisfy({ $0.isFinite && $0 >= 0 }),
              available.width.isFinite, available.height.isFinite,
              available.width > 0, available.height > 0,
              displacement.width.isFinite, displacement.height.isFinite,
              progress.isFinite, windowCornerRadius.isFinite, windowCornerRadius >= 0 else { return nil }
        let fraction = min(1, max(0, progress))
        let scale = 1 - CGFloat(fraction) * 0.32
        let maximumLocalRadius = min(size.width, size.height) / 2
        // The Composer and its inset scale with the live page. Keep the outer
        // radius in that same coordinate space so their corner centers align.
        let radius = min(windowCornerRadius, maximumLocalRadius)
        let pose = SurfaceGeometry.Pose(scale: scale,
            translation: CGSize(width: displacement.width / available.width,
                                height: displacement.height / available.height),
            cornerRadius: radius)
        return pose.isValid ? pose : nil
    }

    /// Compatibility path for scalar callers that only have vertical travel.
    static func interactivePose(size: CGSize, safeArea: UIEdgeInsets,
                                upwardDistance: Double, progress: Double) -> SurfaceGeometry.Pose? {
        guard upwardDistance.isFinite, progress.isFinite,
              CGFloat(upwardDistance).isFinite else { return nil }
        let fraction = min(1, max(0, progress))
        return interactivePose(size: size, safeArea: safeArea,
            displacement: CGSize(width: 0, height: -max(0, CGFloat(upwardDistance))), progress: progress,
            windowCornerRadius: CGFloat(fraction) * 24)
    }

    static func targetPose(size: CGSize, safeArea: UIEdgeInsets,
                           card: CGRect, cornerRadius: CGFloat,
                           constrainedToSafeArea: Bool = true) -> SurfaceGeometry.Pose? {
        guard SurfaceGeometry.resolve(size: size, safeArea: safeArea, request: .full) != nil,
              [card.minX, card.minY, card.width, card.height, card.maxX, card.maxY].allSatisfy({ $0.isFinite }),
              card.width > 0, card.height > 0,
              cornerRadius.isFinite, cornerRadius >= 0,
              cornerRadius <= min(card.width, card.height) / 2 else { return nil }
        let safe = CGRect(x: safeArea.left, y: safeArea.top,
            width: size.width - safeArea.left - safeArea.right,
            height: size.height - safeArea.top - safeArea.bottom)
        guard !constrainedToSafeArea || safe.contains(card) else { return nil }
        // Cover the target uniformly, then crop the outside Surface. The hosting
        // child's logical dimensions and text layout never change with progress.
        let scale = max(card.width / size.width, card.height / size.height)
        let pose = SurfaceGeometry.Pose(scale: scale,
            translation: CGSize(width: (card.midX - size.width / 2) / safe.width,
                                height: (card.midY - size.height / 2) / safe.height),
            cornerRadius: cornerRadius / scale,
            clipFraction: CGSize(width: min(1, card.width / (size.width * scale)),
                                 height: min(1, card.height / (size.height * scale))))
        return pose.isValid ? pose : nil
    }
}

import UIKit

enum SurfaceLiftGeometry {
    /// Interactive transport follows the finger; destination geometry is only
    /// used after release. Uniform scale keeps the complete live page visible.
    static func interactivePose(size: CGSize, safeArea: UIEdgeInsets,
                                upwardDistance: Double, progress: Double) -> SurfaceGeometry.Pose? {
        let available = size.height - safeArea.top - safeArea.bottom
        guard available > 0, available.isFinite, upwardDistance.isFinite, progress.isFinite else { return nil }
        let fraction = min(1, max(0, progress))
        let scale = 1 - CGFloat(fraction) * 0.18
        let pose = SurfaceGeometry.Pose(scale: scale,
            translation: CGSize(width: 0, height: -max(0, upwardDistance) / available),
            cornerRadius: CGFloat(fraction) * 24 / scale)
        return pose.isValid ? pose : nil
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

import UIKit

enum SurfaceLiftGeometry {
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

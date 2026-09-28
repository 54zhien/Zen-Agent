import UIKit

enum SurfaceLiftGeometry {
    // Deliberate compiled RED mutation: the live Surface never leaves Full.
    static func targetPose(size: CGSize, safeArea: UIEdgeInsets,
                           card: CGRect, cornerRadius: CGFloat) -> SurfaceGeometry.Pose? {
        .full
    }
}

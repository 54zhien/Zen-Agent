import UIKit

enum SurfaceGeometry {
    /// Translation is a fraction of the host's safe viewport, in local coordinates.
    struct Pose: Equatable {
        let scale: CGFloat
        let translation: CGSize
        let cornerRadius: CGFloat
        static let full = Pose(scale: 1, translation: .zero, cornerRadius: 0)
    }

    struct Request: Equatable {
        var from: Pose = .full
        var to: Pose = .full
        var progress: CGFloat = 0
        static let full = Request()
    }

    struct Presentation: Equatable {
        let scale: CGFloat
        let translation: CGSize
        let cornerRadius: CGFloat
        static let full = Presentation(scale: 1, translation: .zero, cornerRadius: 0)
    }

    static func resolve(size: CGSize, safeArea: UIEdgeInsets, request: Request) -> Presentation? {
        // Compilable RED scaffold for this new capability; replaced after CI proves assertions fail.
        return .full
    }
}

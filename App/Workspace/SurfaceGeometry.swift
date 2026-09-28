import UIKit

enum SurfaceGeometry {
    /// Translation is a fraction of the host's safe viewport, in local coordinates.
    struct Pose: Equatable, Sendable {
        let scale: CGFloat
        let translation: CGSize
        let cornerRadius: CGFloat
        var clipFraction = CGSize(width: 1, height: 1)
        static let full = Pose(scale: 1, translation: .zero, cornerRadius: 0)

        var isValid: Bool {
            scale.isFinite && scale > 0 && translation.width.isFinite
                && translation.height.isFinite && cornerRadius.isFinite && cornerRadius >= 0
                && clipFraction.width.isFinite && clipFraction.height.isFinite
                && clipFraction.width > 0 && clipFraction.width <= 1
                && clipFraction.height > 0 && clipFraction.height <= 1
        }
    }

    struct Request: Equatable, Sendable {
        var from: Pose = .full
        var to: Pose = .full
        var progress: CGFloat = 0
        static let full = Request()

        var isValid: Bool { progress.isFinite && from.isValid && to.isValid }
    }

    struct Presentation: Equatable, Sendable {
        let scale: CGFloat
        let translation: CGSize
        let cornerRadius: CGFloat
        var clipFraction = CGSize(width: 1, height: 1)
        static let full = Presentation(scale: 1, translation: .zero, cornerRadius: 0)
    }

    static func resolve(size: CGSize, safeArea: UIEdgeInsets, request: Request) -> Presentation? {
        guard request.isValid,
              size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              [safeArea.top, safeArea.left, safeArea.bottom, safeArea.right].allSatisfy({ $0.isFinite && $0 >= 0 })
        else { return nil }

        let available = CGSize(width: size.width - safeArea.left - safeArea.right,
                               height: size.height - safeArea.top - safeArea.bottom)
        guard available.width.isFinite, available.height.isFinite,
              available.width > 0, available.height > 0,
              let from = presentation(for: request.from, size: size, available: available),
              let to = presentation(for: request.to, size: size, available: available)
        else { return nil }

        let progress = min(1, max(0, request.progress))
        // Weighted endpoints avoid overflow when opposite finite translations are far apart.
        func interpolate(_ from: CGFloat, _ to: CGFloat) -> CGFloat {
            (1 - progress) * from + progress * to
        }
        let result = Presentation(scale: interpolate(from.scale, to.scale),
            translation: CGSize(width: interpolate(from.translation.width, to.translation.width),
                                height: interpolate(from.translation.height, to.translation.height)),
            cornerRadius: interpolate(from.cornerRadius, to.cornerRadius),
            clipFraction: CGSize(width: interpolate(from.clipFraction.width, to.clipFraction.width),
                                 height: interpolate(from.clipFraction.height, to.clipFraction.height)))
        guard result.scale.isFinite, result.scale > 0,
              result.translation.width.isFinite, result.translation.height.isFinite,
              result.cornerRadius.isFinite else { return nil }
        return result
    }

    private static func presentation(for pose: Pose, size: CGSize, available: CGSize) -> Presentation? {
        let translation = CGSize(width: available.width * pose.translation.width,
                                 height: available.height * pose.translation.height)
        guard translation.width.isFinite, translation.height.isFinite,
              (size.width * pose.scale).isFinite, (size.height * pose.scale).isFinite
        else { return nil }
        return Presentation(scale: pose.scale, translation: translation, cornerRadius: pose.cornerRadius,
                            clipFraction: pose.clipFraction)
    }
}

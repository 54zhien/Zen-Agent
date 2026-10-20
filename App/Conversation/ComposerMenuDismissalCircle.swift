import UIKit

/// A fixed circle takes over only after live contraction reaches its endpoint.
/// Captured pixels retain their screen coordinates throughout the opacity fade.
@MainActor
final class ComposerMenuDismissalCircle {
    let view = UIView()

    init?(in host: UIView, circle: CGRect) {
        guard let window = host.window,
              circle.width.isFinite, circle.height.isFinite,
              circle.width > 0, circle.width == circle.height else { return nil }
        let crop = host.convert(circle, to: window)
        // Include the just-committed circle, rather than a previous rectangular
        // animation frame. A window capture retains the rendered glass backdrop.
        guard window.bounds.contains(crop),
              let rendered = window.snapshotView(afterScreenUpdates: true) else { return nil }
        view.frame = circle
        view.isOpaque = false
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        // The material circle remains exactly `circle`. Preserve its existing
        // outer shadow too, instead of cutting that shadow off at the handoff.
        let sample = crop.insetBy(dx: -12, dy: -12).intersection(window.bounds)
        let patch = UIView(frame: host.convert(sample, from: window).offsetBy(
            dx: -circle.minX, dy: -circle.minY))
        patch.isOpaque = false
        patch.clipsToBounds = true
        patch.layer.cornerCurve = .circular
        patch.layer.cornerRadius = min(patch.bounds.width, patch.bounds.height) / 2
        rendered.frame = CGRect(x: window.bounds.minX - sample.minX,
                                y: window.bounds.minY - sample.minY,
                                width: window.bounds.width, height: window.bounds.height)
        patch.addSubview(rendered)
        view.addSubview(patch)
        host.addSubview(view)
    }

    func remove() { view.removeFromSuperview() }
}

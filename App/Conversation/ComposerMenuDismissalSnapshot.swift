import UIKit

/// Only the final, already-rendered glass pixels crossfade. Live visual-effect
/// views retain alpha one and do not run a second material-disappearance motion.
@MainActor
final class ComposerMenuDismissalSnapshot {
    let view = UIView()
    private weak var host: UIView?
    private let rendered: UIView
    private let capturedBounds: CGRect

    init?(in host: UIView, frame: CGRect, radius: CGFloat) {
        guard let window = host.window,
              frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0 else { return nil }
        let crop = host.convert(frame, to: window)
        // A leaf effect-view snapshot can omit its backdrop. Capture the host
        // window, then expose only the menu's current region; never persist it.
        guard window.bounds.contains(crop),
              let rendered = window.snapshotView(afterScreenUpdates: false) else { return nil }
        self.host = host
        self.rendered = rendered
        capturedBounds = window.bounds
        view.isOpaque = false
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        view.layer.cornerCurve = .circular
        view.addSubview(rendered)
        place(frame, radius: radius)
        host.addSubview(view)
    }

    func place(_ frame: CGRect, radius: CGFloat) {
        view.frame = frame
        view.layer.cornerRadius = max(0, min(radius, min(frame.width, frame.height) / 2))
        guard let host, let window = host.window else { return }
        let crop = host.convert(frame, to: window)
        // The capture contains backdrop pixels too. Keep their original screen
        // positions and scale; only the outer clipping contour may contract.
        rendered.frame = CGRect(x: capturedBounds.minX - crop.minX,
                                y: capturedBounds.minY - crop.minY,
                                width: capturedBounds.width, height: capturedBounds.height)
    }

    func remove() { view.removeFromSuperview() }
}

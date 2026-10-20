import UIKit

/// Only the final, already-rendered glass pixels crossfade. Live visual-effect
/// views retain alpha one and do not run a second material-disappearance motion.
@MainActor
final class ComposerMenuDismissalSnapshot {
    let view = UIView()
    private let canvas = UIView()
    private let capturedSize: CGSize

    init?(in host: UIView, frame: CGRect, radius: CGFloat) {
        guard let window = host.window,
              frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0 else { return nil }
        let crop = host.convert(frame, to: window)
        // A leaf effect-view snapshot can omit its backdrop. Capture the host
        // window, then expose only the menu's current region; never persist it.
        guard window.bounds.contains(crop),
              let rendered = window.snapshotView(afterScreenUpdates: false) else { return nil }
        capturedSize = frame.size
        view.isOpaque = false
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        view.layer.cornerCurve = .circular
        canvas.isOpaque = false
        canvas.clipsToBounds = true
        rendered.frame = CGRect(x: window.bounds.minX - crop.minX,
                                y: window.bounds.minY - crop.minY,
                                width: window.bounds.width, height: window.bounds.height)
        canvas.addSubview(rendered)
        view.addSubview(canvas)
        place(frame, radius: radius)
        host.addSubview(view)
    }

    func place(_ frame: CGRect, radius: CGFloat) {
        view.frame = frame
        view.layer.cornerRadius = max(0, min(radius, min(frame.width, frame.height) / 2))
        canvas.bounds = CGRect(origin: .zero, size: capturedSize)
        canvas.center = CGPoint(x: frame.width / 2, y: frame.height / 2)
        canvas.transform = CGAffineTransform(scaleX: frame.width / capturedSize.width,
                                            y: frame.height / capturedSize.height)
    }

    func remove() { view.removeFromSuperview() }
}

import UIKit

/// Resolve public container-concentric geometry for the actual scene window.
@MainActor
final class WindowCornerGeometry {
    private weak var cachedWindow: UIWindow?
    private var cachedBounds: CGRect?
    private var cachedRadius: CGFloat = 0

    func radius(in window: UIWindow) -> CGFloat {
        if cachedWindow === window, cachedBounds == window.bounds { return cachedRadius }
        let reference = UIView(frame: window.bounds)
        reference.backgroundColor = .clear
        reference.isUserInteractionEnabled = false
        reference.isAccessibilityElement = false
        reference.accessibilityElementsHidden = true
        reference.cornerConfiguration = .uniformCorners(radius: .containerConcentric())
        window.addSubview(reference)
        reference.layoutIfNeeded()
        let radius = reference.effectiveRadius(corner: .topLeft)
        reference.removeFromSuperview()
        cachedWindow = window
        cachedBounds = window.bounds
        cachedRadius = radius.isFinite ? max(0, radius) : 0
        return cachedRadius
    }
}

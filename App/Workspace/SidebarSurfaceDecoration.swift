import SwiftUI
import UIKit

/// Sidebar decoration owns no content or interaction. Its shadow has no filled
/// backing, and its continuous silhouette is rebuilt only when geometry changes.
@MainActor
final class SidebarSurfaceDecoration {
    let shadowView = UIView()
    private let tintView = UIView()
    private let exteriorShadowMask = CAShapeLayer()
    private var silhouette: Silhouette?
    private var ownsOpacity = false
    private(set) var silhouetteBuildCount = 0

    private struct Silhouette: Equatable {
        let bounds: CGRect
        let radius: CGFloat
        let corners: UInt
    }

    init() {
        shadowView.backgroundColor = .clear
        shadowView.isOpaque = false
        shadowView.isUserInteractionEnabled = false
        shadowView.accessibilityElementsHidden = true
        shadowView.layer.name = "zen-sidebar-shadow"
        shadowView.layer.shadowColor = UIColor.black.cgColor
        shadowView.layer.shadowOpacity = 0.14
        shadowView.layer.shadowRadius = 10
        exteriorShadowMask.fillRule = .evenOdd
        exteriorShadowMask.fillColor = UIColor.black.cgColor
        shadowView.layer.mask = exteriorShadowMask
        shadowView.alpha = 0
        shadowView.isHidden = true
        tintView.backgroundColor = .white
        tintView.isUserInteractionEnabled = false
        tintView.accessibilityElementsHidden = true
        tintView.alpha = 0
        tintView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    func install(on surface: UIView) {
        tintView.frame = surface.bounds
        surface.addSubview(tintView)
    }

    func updateGeometry(surface: UIView, radius: CGFloat, corners: CACornerMask, direction: CGFloat,
                        shadowFrame: CGRect? = nil) {
        let frame = shadowFrame ?? surface.bounds
        shadowView.bounds = CGRect(origin: .zero, size: frame.size)
        shadowView.center = CGPoint(x: surface.center.x + frame.midX - surface.bounds.midX,
                                   y: surface.center.y + frame.midY - surface.bounds.midY)
        shadowView.transform = surface.transform
        shadowView.layer.shadowOffset = CGSize(width: direction * 3, height: 0)
        let next = Silhouette(bounds: shadowView.bounds, radius: radius, corners: corners.rawValue)
        guard silhouette != next else { return }
        silhouette = next
        guard !shadowView.bounds.isEmpty else { shadowView.layer.shadowPath = nil; return }
        func corner(_ mask: CACornerMask) -> CGFloat { corners.contains(mask) ? radius : 0 }
        let outline = UnevenRoundedRectangle(
            topLeadingRadius: corner(.layerMinXMinYCorner),
            bottomLeadingRadius: corner(.layerMinXMaxYCorner),
            bottomTrailingRadius: corner(.layerMaxXMaxYCorner),
            topTrailingRadius: corner(.layerMaxXMinYCorner), style: .continuous
        ).path(in: shadowView.bounds).cgPath
        shadowView.layer.shadowPath = outline
        // shadowPath fills its interior. Remove that interior from the final
        // shadow so Split's inner rounded cutouts cannot expose a blurred slab.
        let padding = ceil(shadowView.layer.shadowRadius * 3
            + max(abs(shadowView.layer.shadowOffset.width), abs(shadowView.layer.shadowOffset.height)))
        let extent = shadowView.bounds.insetBy(dx: -padding, dy: -padding)
        exteriorShadowMask.bounds = extent
        exteriorShadowMask.position = CGPoint(x: shadowView.bounds.midX, y: shadowView.bounds.midY)
        let exterior = CGMutablePath()
        exterior.addRect(extent)
        exterior.addPath(outline)
        exteriorShadowMask.path = exterior
        silhouetteBuildCount += 1
    }

    func applyAppearance(surface: UIView, progress: CGFloat, traits: UITraitCollection) {
        let fraction = min(1, max(0, progress))
        // App Space browsing owns alpha outside Sidebar transport. A closed
        // sidebar must not overwrite a browsed card's independent depth fade.
        guard fraction > 0 || ownsOpacity else { return }
        ownsOpacity = fraction > 0
        let dark = traits.userInterfaceStyle == .dark
        surface.alpha = UIAccessibility.isReduceTransparencyEnabled ? 1 : 1 - fraction * (dark ? 0.10 : 0.06)
        tintView.alpha = dark ? fraction * 0.08 : 0
        surface.layer.borderWidth = dark && fraction > 0 ? 1 / max(1, traits.displayScale) : 0
        surface.layer.borderColor = UIColor.white.withAlphaComponent(0.22 * fraction).cgColor
    }
}

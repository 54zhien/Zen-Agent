import SwiftUI
import UIKit

/// Per-corner radii of a Surface. A resting Split Pane rounds its display
/// corners with the display radius and its divider-facing corners with the
/// smaller Pane radius, which a single `CALayer.cornerRadius` cannot express.
struct SurfaceCornerRadii: Equatable {
    var topLeft: CGFloat
    var topRight: CGFloat
    var bottomLeft: CGFloat
    var bottomRight: CGFloat

    init(uniform radius: CGFloat, corners: CACornerMask) {
        func value(_ corner: CACornerMask) -> CGFloat { corners.contains(corner) ? radius : 0 }
        topLeft = value(.layerMinXMinYCorner)
        topRight = value(.layerMaxXMinYCorner)
        bottomLeft = value(.layerMinXMaxYCorner)
        bottomRight = value(.layerMaxXMaxYCorner)
    }

    init(topLeft: CGFloat, topRight: CGFloat, bottomLeft: CGFloat, bottomRight: CGFloat) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomLeft = bottomLeft
        self.bottomRight = bottomRight
    }

    /// True when one layer radius plus `maskedCorners` already draws this shape.
    var isUniform: Bool {
        Set([topLeft, topRight, bottomLeft, bottomRight].filter { $0 > 0 }).count <= 1
    }

    func path(in rect: CGRect, inset: CGFloat = 0) -> CGPath {
        let rect = rect.insetBy(dx: inset, dy: inset)
        guard !rect.isEmpty else { return CGMutablePath() }
        func r(_ value: CGFloat) -> CGFloat { max(0, value - inset) }
        return UnevenRoundedRectangle(topLeadingRadius: r(topLeft), bottomLeadingRadius: r(bottomLeft),
            bottomTrailingRadius: r(bottomRight), topTrailingRadius: r(topRight), style: .continuous)
            .path(in: rect).cgPath
    }
}

/// Sidebar decoration owns no content or interaction. Its shadow has no filled
/// backing, and its continuous silhouette is rebuilt only when geometry changes.
@MainActor
final class SidebarSurfaceDecoration {
    let shadowView = UIView()
    private let tintView = UIView()
    private let outlineView = OutlineView()
    private var silhouette: Silhouette?
    private var ownsOpacity = false
    private(set) var silhouetteBuildCount = 0
    static let outlineWidth: CGFloat = 0.75

    private struct Silhouette: Equatable {
        let bounds: CGRect
        let radii: SurfaceCornerRadii
    }

    private final class OutlineView: UIView {
        override class var layerClass: AnyClass { CAShapeLayer.self }
        var shape: CAShapeLayer { layer as! CAShapeLayer }
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
        shadowView.alpha = 0
        shadowView.isHidden = true
        tintView.backgroundColor = .white
        tintView.isUserInteractionEnabled = false
        tintView.accessibilityElementsHidden = true
        tintView.alpha = 0
        tintView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        outlineView.backgroundColor = .clear
        outlineView.isUserInteractionEnabled = false
        outlineView.accessibilityElementsHidden = true
        outlineView.alpha = 0
        outlineView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        outlineView.layer.name = "zen-sidebar-page-outline"
        outlineView.shape.fillColor = nil
        outlineView.shape.lineWidth = Self.outlineWidth
    }

    func install(on surface: UIView) {
        tintView.frame = surface.bounds
        surface.addSubview(tintView)
        outlineView.frame = surface.bounds
        surface.addSubview(outlineView)
    }

    /// Visible strength of the hairline drawn around the page while the Sidebar is open.
    var outlineAlpha: CGFloat { outlineView.alpha }

    func updateGeometry(surface: UIView, radii: SurfaceCornerRadii, direction: CGFloat) {
        shadowView.bounds = surface.bounds
        shadowView.center = surface.center
        shadowView.transform = surface.transform
        shadowView.layer.shadowOffset = CGSize(width: direction * 3, height: 0)
        let next = Silhouette(bounds: surface.bounds, radii: radii)
        guard silhouette != next else { return }
        silhouette = next
        guard !surface.bounds.isEmpty else {
            shadowView.layer.shadowPath = nil
            outlineView.shape.path = nil
            return
        }
        shadowView.layer.shadowPath = radii.path(in: surface.bounds)
        // Inset by half the stroke so the Surface's own clip keeps the whole line.
        outlineView.shape.path = radii.path(in: surface.bounds, inset: Self.outlineWidth / 2)
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
        // The same gray the Split divider fades into, so divider and outline
        // read as one line wrapping the page in both appearances.
        outlineView.shape.strokeColor = SidebarProgressPresentation.edgeColor(traits: traits).cgColor
        outlineView.alpha = fraction
    }
}

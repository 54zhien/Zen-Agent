import SwiftUI
import UIKit

/// Shared by native Conversation Surfaces and the SwiftUI Split picker.
struct SidebarPageAppearance {
    let surfaceOpacity: CGFloat
    let tintOpacity: CGFloat
    let outlineOpacity: CGFloat

    init(progress: CGFloat, dark: Bool, reduceTransparency: Bool) {
        let fraction = progress.isFinite ? min(1, max(0, progress)) : 0
        surfaceOpacity = reduceTransparency ? 1 : 1 - fraction * (dark ? 0.10 : 0.06)
        tintOpacity = dark ? fraction * 0.08 : 0
        outlineOpacity = fraction
    }

    func surfaceColor(resolving traits: UITraitCollection) -> UIColor {
        let surface = UIColor.systemBackground.resolvedColor(with: traits)
        var red: CGFloat = 1
        var green: CGFloat = 1
        var blue: CGFloat = 1
        var alpha: CGFloat = 1
        guard surface.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return surface }
        // A tinted page over this same color has no seam, even while the page
        // itself is translucent. Multiplying the tint by page alpha darkens it twice.
        func tinted(_ component: CGFloat) -> CGFloat { component + (1 - component) * tintOpacity }
        return UIColor(red: tinted(red), green: tinted(green), blue: tinted(blue), alpha: alpha)
    }
}

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
    private let exteriorShadowMask = CAShapeLayer()
    private let outlineView = OutlineView()
    private var shadowSilhouette: ShadowSilhouette?
    private var outlineSilhouette: OutlineSilhouette?
    private var ownsOpacity = false
    private(set) var silhouetteBuildCount = 0
    static let outlineWidth: CGFloat = 0.75

    private struct ShadowSilhouette: Equatable {
        let bounds: CGRect
        let radii: SurfaceCornerRadii
    }

    private struct OutlineSilhouette: Equatable {
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

    func setOutlineExternallyDrawn(_ value: Bool) {
        outlineView.isHidden = value
    }

    func updateGeometry(surface: UIView, radius: CGFloat, corners: CACornerMask, direction: CGFloat,
                        shadowFrame: CGRect? = nil) {
        updateGeometry(surface: surface, radii: SurfaceCornerRadii(uniform: radius, corners: corners),
            direction: direction, shadowFrame: shadowFrame)
    }

    func updateGeometry(surface: UIView, radii: SurfaceCornerRadii, direction: CGFloat,
                        shadowFrame: CGRect? = nil, shadowRadii: SurfaceCornerRadii? = nil) {
        let frame = shadowFrame ?? surface.bounds
        let shadowRadii = shadowRadii ?? radii
        shadowView.bounds = CGRect(origin: .zero, size: frame.size)
        shadowView.center = CGPoint(x: surface.center.x + frame.midX - surface.bounds.midX,
                                   y: surface.center.y + frame.midY - surface.bounds.midY)
        shadowView.transform = surface.transform
        shadowView.layer.shadowOffset = CGSize(width: direction * 3, height: 0)
        let nextShadow = ShadowSilhouette(bounds: shadowView.bounds, radii: shadowRadii)
        if shadowSilhouette != nextShadow {
            shadowSilhouette = nextShadow
            if shadowView.bounds.isEmpty {
                shadowView.layer.shadowPath = nil
                exteriorShadowMask.path = nil
            } else {
                let shadowPath = shadowRadii.path(in: shadowView.bounds)
                shadowView.layer.shadowPath = shadowPath
                // The shared workspace shadow must stay outside its silhouette, including
                // rounded cutouts of an individual Pane above the picker.
                let padding = ceil(shadowView.layer.shadowRadius * 3
                    + max(abs(shadowView.layer.shadowOffset.width), abs(shadowView.layer.shadowOffset.height)))
                let extent = shadowView.bounds.insetBy(dx: -padding, dy: -padding)
                exteriorShadowMask.bounds = extent
                exteriorShadowMask.position = CGPoint(x: shadowView.bounds.midX, y: shadowView.bounds.midY)
                let exterior = CGMutablePath()
                exterior.addRect(extent)
                exterior.addPath(shadowPath)
                exteriorShadowMask.path = exterior
            }
            silhouetteBuildCount += 1
        }
        updateOutlineGeometry(surface: surface, radii: radii)
    }

    /// Pane outlines are visible on every translated page, including the Split
    /// picker that deliberately does not own the workspace's shared shadow.
    func updateOutlineGeometry(surface: UIView, radii: SurfaceCornerRadii) {
        let next = OutlineSilhouette(bounds: surface.bounds, radii: radii)
        guard outlineSilhouette != next else { return }
        outlineSilhouette = next
        guard !surface.bounds.isEmpty else {
            outlineView.shape.path = nil
            return
        }
        // Inset by half the stroke so the Surface's own clip keeps the whole line.
        outlineView.shape.path = radii.path(in: surface.bounds, inset: Self.outlineWidth / 2)
    }

    func applyAppearance(surface: UIView, progress: CGFloat, traits: UITraitCollection) {
        let fraction = min(1, max(0, progress))
        // App Space owns its Surface outside Sidebar transport. A closed
        // sidebar must not overwrite that presentation on every browse frame.
        guard fraction > 0 || ownsOpacity else { return }
        ownsOpacity = fraction > 0
        let appearance = SidebarPageAppearance(progress: fraction, dark: traits.userInterfaceStyle == .dark,
            reduceTransparency: UIAccessibility.isReduceTransparencyEnabled)
        surface.alpha = appearance.surfaceOpacity
        tintView.alpha = appearance.tintOpacity
        // Every Pane keeps the same progressive hairline in either appearance.
        outlineView.shape.strokeColor = SidebarProgressPresentation.edgeColor(traits: traits).cgColor
        outlineView.alpha = appearance.outlineOpacity
    }
}

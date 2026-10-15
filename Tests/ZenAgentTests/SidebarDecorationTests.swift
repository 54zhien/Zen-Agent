import UIKit
import Testing
@testable import ZenAgent

@Suite("Sidebar native decoration ownership")
@MainActor
struct SidebarDecorationTests {
    @Test("transport reuses a transparent shadow silhouette until its geometry changes")
    func translationDoesNotRebuildOrFillTheShadow() throws {
        let surface = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let decoration = SidebarSurfaceDecoration()
        decoration.install(on: surface)
        let corners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        decoration.updateGeometry(surface: surface, radius: 62, corners: corners, direction: -1)
        let first = decoration.silhouetteBuildCount
        let path = try #require(decoration.shadowView.layer.shadowPath)
        #expect(!decoration.shadowView.isOpaque)
        #expect(decoration.shadowView.backgroundColor?.cgColor.alpha == 0,
                "A shadow must not add an opaque page-colored backing at the rounded corners")
        for step in 1...40 {
            surface.center.x += CGFloat(step) / 4
            decoration.updateGeometry(surface: surface, radius: 62, corners: corners, direction: -1)
        }
        #expect(decoration.silhouetteBuildCount == first)
        #expect(decoration.shadowView.layer.shadowPath === path)
        #expect(decoration.shadowView.center == surface.center)
        surface.bounds.size.height -= 40
        decoration.updateGeometry(surface: surface, radius: 62, corners: corners, direction: -1)
        #expect(decoration.silhouetteBuildCount == first + 1)
        #expect(decoration.shadowView.layer.shadowPath?.boundingBoxOfPath == surface.bounds)
    }

    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func progressOwnsAlphaOnlyWhileSidebarIsVisible(style: UIUserInterfaceStyle) throws {
        let surface = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let decoration = SidebarSurfaceDecoration()
        decoration.install(on: surface)
        let traits = UITraitCollection(traitsFrom: [UITraitCollection(userInterfaceStyle: style), UITraitCollection(displayScale: 3)])
        surface.alpha = 0.6
        decoration.applyAppearance(surface: surface, progress: 0, traits: traits)
        #expect(surface.alpha == 0.6, "An idle Sidebar must leave App Space's card depth opacity alone")
        decoration.applyAppearance(surface: surface, progress: 0.25, traits: traits)
        let early = surface.alpha
        decoration.applyAppearance(surface: surface, progress: 0.75, traits: traits)
        if !UIAccessibility.isReduceTransparencyEnabled {
            #expect(surface.alpha < early && surface.alpha > 0.8, "The page fades gradually while remaining readable")
        }
        let tint = try #require(surface.subviews.last)
        #expect(style == .dark ? tint.alpha > 0 : tint.alpha == 0)
        #expect(style == .dark ? surface.layer.borderWidth > 0 : surface.layer.borderWidth == 0)
        decoration.applyAppearance(surface: surface, progress: 0, traits: traits)
        #expect(surface.alpha == 1 && tint.alpha == 0 && surface.layer.borderWidth == 0)
        surface.alpha = 0.55
        decoration.applyAppearance(surface: surface, progress: 0, traits: traits)
        #expect(surface.alpha == 0.55)
    }
}

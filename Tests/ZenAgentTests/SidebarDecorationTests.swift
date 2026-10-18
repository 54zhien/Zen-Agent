import UIKit
import Testing
@testable import ZenAgent

@Suite("Sidebar native decoration ownership")
@MainActor
struct SidebarDecorationTests {
    @Test func sharedShadowDoesNotFillTheConversationCornerAboveThePicker() throws {
        let surface = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 420))
        let decoration = SidebarSurfaceDecoration()
        let corners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner,
                                    .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        decoration.updateGeometry(surface: surface, radius: 62, corners: corners, direction: -1,
            shadowFrame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let mask = try #require(decoration.shadowView.layer.mask as? CAShapeLayer)
        let path = try #require(mask.path)
        #expect(mask.fillRule == .evenOdd)
        // These cutouts lie inside the overall workspace silhouette; a filled
        // shadow would remain visible where the individual Pane is rounded away.
        for point in [CGPoint(x: 2, y: 418), CGPoint(x: 12, y: 416),
                      CGPoint(x: 201, y: 424), CGPoint(x: 2, y: 440)] {
            #expect(!path.contains(point, using: .evenOdd))
        }
        #expect(path.contains(CGPoint(x: -4, y: 210), using: .evenOdd))
        surface.center.x += 96
        decoration.updateGeometry(surface: surface, radius: 62, corners: corners, direction: -1,
            shadowFrame: CGRect(x: 0, y: 0, width: 402, height: 874))
        #expect(mask.path === path, "Sidebar translation must reuse the exterior mask")
    }

    @Test(arguments: [CGRect(x: 0, y: 0, width: 402, height: 420),
                      CGRect(x: 0, y: 428, width: 402, height: 446),
                      CGRect(x: 206, y: 0, width: 196, height: 874)])
    func splitOwnerUsesTheSingleWorkspaceSilhouette(pane: CGRect) throws {
        let workspace = CGRect(x: 0, y: 0, width: 402, height: 874)
        let single = UIView(frame: workspace)
        let split = UIView(frame: CGRect(origin: .zero, size: pane.size))
        let singleDecoration = SidebarSurfaceDecoration()
        let splitDecoration = SidebarSurfaceDecoration()
        let corners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner,
                                    .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        let sharedFrame = workspace.offsetBy(dx: -pane.minX, dy: -pane.minY)
        for offset in [CGFloat(0), 24, 96] {
            single.center.x = workspace.midX + offset
            split.center.x = pane.width / 2 + offset
            singleDecoration.updateGeometry(surface: single, radius: 62, corners: corners, direction: -1)
            splitDecoration.updateGeometry(surface: split, radius: 62, corners: corners, direction: -1,
                shadowFrame: sharedFrame)
            let singlePath = try #require(singleDecoration.shadowView.layer.shadowPath)
            let splitPath = try #require(splitDecoration.shadowView.layer.shadowPath)
            #expect(singlePath == splitPath)
            let localCenter = splitDecoration.shadowView.center
            #expect(CGPoint(x: localCenter.x + pane.minX, y: localCenter.y + pane.minY)
                == singleDecoration.shadowView.center)
        }
        #expect(splitDecoration.silhouetteBuildCount == 1)
    }

    @Test(arguments: [false, true])
    func pageAppearanceIsSharedByNativeAndPickerPages(dark: Bool) {
        let closed = SidebarPageAppearance(progress: 0, dark: dark, reduceTransparency: false)
        let open = SidebarPageAppearance(progress: 1, dark: dark, reduceTransparency: false)
        #expect(closed.surfaceOpacity == 1 && closed.tintOpacity == 0 && closed.outlineOpacity == 0)
        #expect(abs(open.surfaceOpacity - (dark ? 0.90 : 0.94)) < 0.001)
        #expect(open.tintOpacity == (dark ? 0.08 : 0))
        #expect(open.outlineOpacity == 1)
        let accessible = SidebarPageAppearance(progress: 1, dark: dark, reduceTransparency: true)
        #expect(accessible.surfaceOpacity == 1)
    }

    @Test
    func dockCanOwnTheOutlineWithoutChangingThePageAppearance() throws {
        let surface = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 400))
        let decoration = SidebarSurfaceDecoration()
        decoration.install(on: surface)
        let outline = try #require(surface.subviews.first { $0.layer.name == "zen-sidebar-page-outline" })
        let traits = UITraitCollection(userInterfaceStyle: .dark)
        decoration.setOutlineExternallyDrawn(true)
        decoration.applyAppearance(surface: surface, progress: 1, traits: traits)
        #expect(outline.isHidden)
        #expect(decoration.outlineAlpha == 1)
        let pageAlpha = surface.alpha
        decoration.setOutlineExternallyDrawn(false)
        #expect(!outline.isHidden)
        #expect(surface.alpha == pageAlpha)
    }

    @Test("transport reuses a transparent shadow silhouette until its geometry changes")
    func translationDoesNotRebuildOrFillTheShadow() throws {
        let surface = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let decoration = SidebarSurfaceDecoration()
        decoration.install(on: surface)
        let radii = SurfaceCornerRadii(uniform: 62, corners: [.layerMinXMinYCorner, .layerMaxXMinYCorner,
                                                               .layerMinXMaxYCorner, .layerMaxXMaxYCorner])
        decoration.updateGeometry(surface: surface, radii: radii, direction: -1)
        let first = decoration.silhouetteBuildCount
        let path = try #require(decoration.shadowView.layer.shadowPath)
        #expect(!decoration.shadowView.isOpaque)
        #expect(decoration.shadowView.backgroundColor?.cgColor.alpha == 0,
                "A shadow must not add an opaque page-colored backing at the rounded corners")
        for step in 1...40 {
            surface.center.x += CGFloat(step) / 4
            decoration.updateGeometry(surface: surface, radii: radii, direction: -1)
        }
        #expect(decoration.silhouetteBuildCount == first)
        #expect(decoration.shadowView.layer.shadowPath === path)
        #expect(decoration.shadowView.center == surface.center)
        surface.bounds.size.height -= 40
        decoration.updateGeometry(surface: surface, radii: radii, direction: -1)
        #expect(decoration.silhouetteBuildCount == first + 1)
        #expect(decoration.shadowView.layer.shadowPath?.boundingBoxOfPath == surface.bounds)
    }

    @Test("a resting Split Pane rounds display corners and divider corners independently")
    func unevenRadiiFollowDisplayAndDividerCorners() {
        let viewport = CGRect(x: 0, y: 0, width: 402, height: 874)
        let layout = SplitWorkspaceGeometry(viewport: viewport, ratio: 0.5)!
        #expect(SplitWorkspaceGeometry.viewportCorners(of: layout.top, in: viewport)
                == [.layerMinXMinYCorner, .layerMaxXMinYCorner])
        #expect(SplitWorkspaceGeometry.viewportCorners(of: layout.bottom, in: viewport)
                == [.layerMinXMaxYCorner, .layerMaxXMaxYCorner])
        #expect(SplitWorkspaceGeometry.viewportCorners(of: viewport, in: viewport).rawValue == 15)
        let uniform = SurfaceCornerRadii(uniform: 24, corners: [.layerMinXMinYCorner, .layerMaxXMaxYCorner])
        #expect(uniform.isUniform)
        let pane = SurfaceCornerRadii(topLeft: 62, topRight: 62, bottomLeft: 24, bottomRight: 24)
        #expect(!pane.isUniform)
        #expect(pane.path(in: layout.top).boundingBoxOfPath == layout.top)
    }

    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func progressOwnsAlphaOnlyWhileSidebarIsVisible(style: UIUserInterfaceStyle) throws {
        let surface = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let decoration = SidebarSurfaceDecoration()
        decoration.install(on: surface)
        let traits = UITraitCollection(traitsFrom: [UITraitCollection(userInterfaceStyle: style), UITraitCollection(displayScale: 3)])
        surface.alpha = 0.6
        let browseAlpha = surface.alpha
        decoration.applyAppearance(surface: surface, progress: 0, traits: traits)
        #expect(surface.alpha == browseAlpha, "An idle Sidebar must leave App Space's card depth opacity alone")
        decoration.applyAppearance(surface: surface, progress: 0.25, traits: traits)
        let early = surface.alpha
        decoration.applyAppearance(surface: surface, progress: 0.75, traits: traits)
        if !UIAccessibility.isReduceTransparencyEnabled {
            #expect(surface.alpha < early && surface.alpha > 0.8, "The page fades gradually while remaining readable")
        }
        let tint = try #require(surface.subviews.first)
        #expect(style == .dark ? tint.alpha > 0 : tint.alpha == 0)
        #expect(decoration.outlineAlpha == 0.75, "Both appearances outline the page as the Sidebar opens")
        decoration.applyAppearance(surface: surface, progress: 0, traits: traits)
        #expect(surface.alpha == 1 && tint.alpha == 0 && decoration.outlineAlpha == 0)
        surface.alpha = 0.55
        let restoredBrowseAlpha = surface.alpha
        decoration.applyAppearance(surface: surface, progress: 0, traits: traits)
        #expect(surface.alpha == restoredBrowseAlpha)
    }
}

import SwiftUI
import UIKit
import Testing
@testable import ZenAgent

@Suite("Retained Sidebar native Surface")
@MainActor
struct SidebarSurfaceTests {
    @Test("a floating window-concentric pose is not enlarged by the resting Split corner minimum")
    func floatingCornersUseTheResolvedPose() {
        let host = ConversationSurfaceViewController(content: Color.clear)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        host.setRestingCornerRadius(24)
        let scale: CGFloat = 0.82
        let visibleRadius: CGFloat = 18
        let pose = SurfaceGeometry.Pose(scale: scale, translation: .zero, cornerRadius: visibleRadius / scale)
        #expect(host.apply(.init(to: pose, progress: 1)))
        #expect(abs(host.surfaceView.layer.cornerRadius * host.surfaceView.transform.a - visibleRadius) < 0.01,
                "The physical window radius must survive the floating scale on iPad as well as iPhone")
        #expect(host.sidebarSilhouetteBuildCount == 0,
                "An invisible Sidebar must not rebuild shadow geometry during Lift")
    }

    @Test("the exposed Rail receives native hit testing beneath a translated Full Surface")
    func exposedRailPassesTouchesToItsUnderlyingButton() {
        let root = UIViewController()
        let host = ConversationSurfaceViewController(content: Color.clear, request: .full)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let rail = UIButton(type: .system)
        rail.frame = CGRect(x: 0, y: 100, width: 60, height: 60)
        root.view.addSubview(rail)
        root.addChild(host); root.view.addSubview(host.view); host.didMove(toParent: root)
        host.view.frame = root.view.bounds; host.view.layoutIfNeeded()
        host.setSidebar(offset: 60, settlement: nil, completion: nil)
        #expect(root.view.hitTest(CGPoint(x: 30, y: 130), with: nil) === rail)
        #expect(host.view.hitTest(CGPoint(x: 150, y: 130), with: nil) != nil)
        host.cancelSidebar()
        #expect(root.view.hitTest(CGPoint(x: 30, y: 130), with: nil) !== rail)
    }

    @Test func nativeLayoutRetainsNavigationCenterWithoutChangingLiftTransformOrHostBounds() {
        let host = ConversationSurfaceViewController(content: Text("Retained content"), request: .full)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        let bounds = host.surfaceView.bounds
        let transform = host.surfaceView.transform
        let child = host.contentController
        host.setSidebar(offset: 90, settlement: nil, completion: nil)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        #expect(host.surfaceView.center.x == host.view.bounds.midX + 90)
        #expect(host.surfaceView.bounds == bounds && host.surfaceView.transform == transform)
        #expect(host.contentController === child)
        host.cancelSidebar()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        #expect(host.surfaceView.center.x == host.view.bounds.midX)
        #expect(host.surfaceView.bounds == bounds && host.contentController === child)
    }

    @Test("the shifted conversation surface follows UIKit's containing-window corner radius")
    func sidebarSurfaceUsesNativeContainerConcentricCornerRadius() throws {
        let scene = try #require(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let host = ConversationSurfaceViewController(content: Color.clear, request: .full)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }

        host.view.layoutIfNeeded()
        let reference = UIView(frame: window.bounds)
        reference.cornerConfiguration = .uniformCorners(radius: .containerConcentric())
        reference.backgroundColor = .clear
        reference.isUserInteractionEnabled = false
        reference.isAccessibilityElement = false
        reference.accessibilityElementsHidden = true
        window.addSubview(reference)
        reference.layoutIfNeeded()
        let expectedRadius = reference.effectiveRadius(corner: .topLeft)
        reference.removeFromSuperview()

        host.setSidebar(offset: 60, settlement: nil, completion: nil)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        #expect(expectedRadius > 0, "UIKit must resolve the public container-concentric probe in this window")
        #expect(abs(host.surfaceView.layer.cornerRadius - expectedRadius) <= 0.5,
                "The translated foreground Surface must use the window's resolved corner radius")
    }

    @Test func liveNavigationBlocksLiftUntilItsMatchingNativeCompletion() throws {
        let state = WorkspaceNavigationState()
        let lift = SurfaceLiftController()
        lift.workspaceNavigation = state
        #expect(!lift.workspaceNavigationActive)
        #expect(state.openSidebar(eligible: true))
        #expect(lift.workspaceNavigationActive)
        state.closeSidebar()
        #expect(lift.workspaceNavigationActive)
        state.completeSettlement(try #require(state.settlementID))
        #expect(!lift.workspaceNavigationActive)
    }
}

import SwiftUI
import UIKit
import Testing
@testable import ZenAgent

@Suite("Lift host transport", .serialized)
@MainActor
struct SurfaceLiftHostTests {
    @Test func cropChangesVisibleBoundaryAndHitRegionWithoutRelayout() throws {
        let host = ConversationSurfaceViewController(content: Text("retained content"))
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        host.view.layoutIfNeeded()
        let child = host.contentController
        let bounds = child.view.bounds
        var pose = SurfaceGeometry.Pose(scale: 0.75, translation: .zero, cornerRadius: 24)
        pose.clipFraction = CGSize(width: 0.8, height: 0.65)
        #expect(host.apply(.init(to: pose, progress: 1)))
        let mask = try #require(host.surfaceView.mask)
        #expect(mask.frame == CGRect(x: 40, y: 140, width: 320, height: 520))
        #expect(host.surfaceView.hitTest(CGPoint(x: 20, y: 400), with: nil) == nil)
        #expect(host.contentController === child && child.view.bounds == bounds)
        let previous = host.presentation
        pose.clipFraction = .zero
        #expect(!host.apply(.init(to: pose, progress: 1)))
        #expect(host.presentation == previous)
        #expect(host.apply(.full))
        #expect(host.surfaceView.mask == nil)
        #expect(host.contentController === child && child.view.bounds == bounds)
    }

    @Test func boundDriverPresentsCardAndReturnsSameChild() throws {
        let host = ConversationSurfaceViewController(content: Text("same child"))
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        host.view.layoutIfNeeded()
        let child = host.contentController
        let driver = SurfaceLiftController()
        driver.bind(host)
        #expect(driver.arm(SurfaceLiftEligibility()))
        #expect(driver.drag(upwardDistance: 180, eligibility: SurfaceLiftEligibility()))
        let settle = driver.end(animated: false)
        #expect(settle?.destination == .card)
        #expect(driver.state.phase == .card)
        #expect(host.presentation.scale < 1)
        #expect(!child.view.isUserInteractionEnabled)
        #expect(child.view.accessibilityElementsHidden)
        #expect(host.surfaceView.isAccessibilityElement)
        #expect(driver.returnToFull(animated: false))
        #expect(driver.state.phase == .full)
        #expect(host.presentation == .full)
        #expect(child.view.isUserInteractionEnabled)
        #expect(!child.view.accessibilityElementsHidden)
        #expect(host.contentController === child)
    }

    @Test func selectionAggregationAndOverlayInvalidateCurrentLift() {
        let host = ConversationSurfaceViewController(content: Text("guarded"))
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        host.view.layoutIfNeeded()
        let driver = SurfaceLiftController()
        driver.bind(host)
        driver.setSelection(sourceID: "part-a", active: true)
        driver.setSelection(sourceID: "part-b", active: false)
        #expect(driver.hasSelection)
        #expect(!driver.canArm(SurfaceLiftEligibility()))
        #expect(!driver.arm(SurfaceLiftEligibility()))
        driver.setSelection(sourceID: "part-a", active: false)
        #expect(driver.arm(SurfaceLiftEligibility()))
        #expect(driver.drag(upwardDistance: 96, eligibility: SurfaceLiftEligibility()))
        driver.setOverlayPresented(true)
        #expect(driver.state.phase == .full && host.presentation == .full)
        #expect(!driver.canArm(SurfaceLiftEligibility()))
    }

    @Test func interruptedAnimatorCannotReapplyCardAfterReturn() async throws {
        let host = ConversationSurfaceViewController(content: Text("interruptible"))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        let child = host.contentController
        let driver = SurfaceLiftController()
        driver.bind(host)
        #expect(driver.arm(SurfaceLiftEligibility()))
        #expect(driver.drag(upwardDistance: 120, eligibility: SurfaceLiftEligibility()))
        #expect(driver.end() != nil)
        try await Task.sleep(for: .milliseconds(40))
        #expect(driver.returnToFull(animated: false))
        #expect(driver.state.phase == .full && host.presentation == .full)
        try await Task.sleep(for: .milliseconds(450))
        #expect(driver.state.phase == .full && host.presentation == .full)
        #expect(host.contentController === child)
        #expect(child.view.isUserInteractionEnabled && !child.view.accessibilityElementsHidden)
    }

    @Test func viewportChangeCancelsBoundLiftAndRequiresFreshGesture() {
        let host = ConversationSurfaceViewController(content: Text("resize"))
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        host.view.layoutIfNeeded()
        let driver = SurfaceLiftController()
        driver.bind(host)
        #expect(driver.arm(SurfaceLiftEligibility()))
        #expect(driver.drag(upwardDistance: 96, eligibility: SurfaceLiftEligibility()))
        host.view.frame = CGRect(x: 0, y: 0, width: 800, height: 400)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        #expect(driver.state.phase == .full && host.presentation == .full)
        #expect(!driver.drag(upwardDistance: 180, eligibility: SurfaceLiftEligibility()))
        #expect(driver.end() == nil)
    }
}

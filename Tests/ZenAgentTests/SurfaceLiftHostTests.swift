import SwiftUI
import UIKit
import Testing
@testable import ZenAgent

@Suite("Lift host transport", .serialized)
@MainActor
struct SurfaceLiftHostTests {
    @Test func settlingSurfaceActivationReversesAndReturnReentryIsIdempotent() async throws {
        let host = ConversationSurfaceViewController(content: Text("production activation"))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        let child = host.contentController
        let driver = SurfaceLiftController()
        driver.bind(host)
        #expect(driver.arm(SurfaceLiftEligibility()))
        #expect(driver.drag(upwardDistance: 120, eligibility: SurfaceLiftEligibility()))
        let outgoing = try #require(driver.end())
        let animator = try #require(host.liftAnimatorForTesting)
        animator.pauseAnimation()
        animator.fractionComplete = 0.25
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(40))
        #expect(driver.state.phase == .settling)
        #expect(!child.view.isUserInteractionEnabled && child.view.accessibilityElementsHidden)
        #expect(host.surfaceView.isAccessibilityElement)
        #expect(host.surfaceView.accessibilityCustomActions?.count == 1)
        #expect(host.surfaceView.accessibilityActivate())
        let returning = driver.state.pendingSettlement
        #expect(returning?.destination == .full)
        #expect(returning?.identity != outgoing.identity)
        #expect((returning?.startProgress ?? 0) >= outgoing.startProgress)
        #expect((returning?.startProgress ?? 1) < 1)
        #expect(host.surfaceView.activateReturn())
        #expect(driver.state.pendingSettlement == returning)
        try await Task.sleep(for: .milliseconds(450))
        #expect(driver.state.phase == .full && host.presentation == .full)
        #expect(host.contentController === child)
        #expect(child.view.isUserInteractionEnabled && !child.view.accessibilityElementsHidden)
        #expect(host.surfaceView.onActivate == nil)
        #expect(driver.arm(SurfaceLiftEligibility()))
        driver.invalidate()
    }

    @Test func settlingTouchHitUsesVisibleAnimationRatherThanModelEndpoint() async throws {
        let host = ConversationSurfaceViewController(content: Text("visible touch"))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        let driver = SurfaceLiftController()
        driver.bind(host)
        #expect(driver.arm(SurfaceLiftEligibility()))
        #expect(driver.drag(upwardDistance: 120, eligibility: SurfaceLiftEligibility()))
        #expect(driver.end() != nil)
        let animator = try #require(host.liftAnimatorForTesting)
        animator.pauseAnimation()
        animator.fractionComplete = 0.25
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(40))
        #expect(driver.state.phase == .settling)
        let visibleLayer = try #require(host.surfaceView.layer.presentation())
        let visibleMask = try #require(visibleLayer.mask)
        let visibleParent = try #require(visibleLayer.superlayer)
        let visibleFrame = visibleLayer.convert(visibleMask.frame, to: visibleParent)
        let modelFrame = host.surfaceView.convert(try #require(host.surfaceView.visibleRect), to: host.view)
        // Pick pixels still visible above the final Card's model hit region.
        #expect(visibleFrame.minY < modelFrame.minY - 2)
        let point = CGPoint(x: visibleFrame.midX, y: (visibleFrame.minY + modelFrame.minY) / 2)
        #expect(!modelFrame.contains(point))
        #expect(host.view.hitTest(point, with: nil) === host.surfaceView)
        #expect(host.view.hitTest(.zero, with: nil) !== host.surfaceView)
        driver.invalidate()
    }

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

    @Test func lateGestureEventsDoNotOverwriteAnimatorEndpoint() async throws {
        let host = ConversationSurfaceViewController(content: Text("late gesture"))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        let driver = SurfaceLiftController()
        driver.bind(host)
        #expect(driver.arm(SurfaceLiftEligibility()))
        #expect(driver.drag(upwardDistance: 120, eligibility: SurfaceLiftEligibility()))
        #expect(driver.end() != nil)
        #expect(driver.state.phase == .settling)
        let endpoint = host.presentation
        #expect(!driver.drag(upwardDistance: 96, eligibility: SurfaceLiftEligibility()))
        #expect(driver.end() == nil)
        #expect(host.presentation == endpoint)
        try await Task.sleep(for: .milliseconds(450))
        #expect(driver.state.phase == .card)
        #expect(host.presentation == endpoint)
        #expect(driver.returnToFull(animated: false))
    }

    @Test func nativeTextSourceRegistrationsStayIndependentAndDismantle() {
        let driver = SurfaceLiftController()
        func source(_ id: String) -> QuoteSourceText {
            QuoteSourceText(conversationID: "selection", messageID: "message", partID: id,
                            text: "selected source", isCompleted: true)
        }
        let a = QuoteSelectableText.Coordinator(parent: QuoteSelectableText(
            text: "selected source", source: source("a"), typographyRole: .conversationBody,
            dynamicTypeSize: .large))
        let b = QuoteSelectableText.Coordinator(parent: QuoteSelectableText(
            text: "selected source", source: source("b"), typographyRole: .conversationBody,
            dynamicTypeSize: .large))
        let textA = UITextView()
        textA.isEditable = false
        textA.text = "selected source"
        textA.selectedRange = NSRange(location: 0, length: 3)
        let textB = UITextView()
        textB.isEditable = false
        textB.text = "selected source"
        textB.selectedRange = NSRange(location: 0, length: 0)
        a.textView = textA
        b.textView = textB
        a.setLiftDriver(driver)
        b.setLiftDriver(driver)
        #expect(driver.hasSelection)
        b.textViewDidChangeSelection(textB)
        #expect(driver.hasSelection)
        QuoteSelectableText.dismantleUIView(textB, coordinator: b)
        #expect(driver.hasSelection)
        QuoteSelectableText.dismantleUIView(textA, coordinator: a)
        #expect(!driver.hasSelection)
    }
}

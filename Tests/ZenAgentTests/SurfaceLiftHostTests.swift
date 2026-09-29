import SwiftUI
import UIKit
import Testing
@testable import ZenAgent

@Suite("Lift host transport", .serialized)
@MainActor
struct SurfaceLiftHostTests {
    @Test func interruptedReturnResetsTheActualNativeTransform() async throws {
        let host = ConversationSurfaceViewController(content: Text("interrupted Return"))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        let pose = SurfaceGeometry.Pose(scale: 0.7, translation: CGSize(width: 0, height: -0.1), cornerRadius: 24)
        host.animateLift(target: pose, from: 1, to: 0, animated: true) { _ in }
        let animator = try #require(host.liftAnimatorForTesting)
        animator.pauseAnimation()
        animator.fractionComplete = 0.4
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(40))
        #expect(host.presentation == .full)
        host.resetLiftPresentation()
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(40))
        #expect(host.surfaceView.transform == .identity)
        #expect(abs((host.surfaceView.layer.presentation()?.transform.m11 ?? 1) - 1) < 0.001)
        #expect(host.surfaceView.mask == nil)
    }

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

    @Test func splitIntentKeepsCapturedConversationAndRejectedDropReturnsSameSurface() throws {
        let host = ConversationSurfaceViewController(content: Text("retained Split source"))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        let child = host.contentController
        let driver = SurfaceLiftController()
        driver.bind(host)
        var entries = 0
        var delivered: SplitDropIntent?
        driver.onSplitTargetEntry = { entries += 1 }
        driver.configureSplit { intent in delivered = intent; return false }
        #expect(driver.arm(SurfaceLiftEligibility(), conversationID: "captured"))
        #expect(driver.drag(upwardDistance: 320, eligibility: SurfaceLiftEligibility(),
                            locationInWindow: CGPoint(x: 200, y: 160)))
        #expect(driver.splitTargetSlot == .top)
        #expect(entries == 1)
        #expect(driver.drag(upwardDistance: 325, eligibility: SurfaceLiftEligibility(),
                            locationInWindow: CGPoint(x: 200, y: 150)))
        #expect(entries == 1)
        #expect(host.presentation != .full)
        _ = driver.end(animated: false)
        #expect(delivered == SplitDropIntent(conversationID: "captured", slot: .top))
        #expect(driver.lastSplitDropIntent == delivered)
        #expect(driver.state.phase == .full && host.presentation == .full)
        #expect(host.contentController === child)
    }

    @Test func splitCancellationCannotDeliverAndInvalidationRestoresNativePixels() {
        let host = ConversationSurfaceViewController(content: Text("cancelled Split source"))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        let driver = SurfaceLiftController()
        driver.bind(host)
        var deliveries = 0
        driver.configureSplit { _ in deliveries += 1; return true }
        #expect(driver.arm(SurfaceLiftEligibility(), conversationID: "source"))
        #expect(driver.drag(upwardDistance: 320, eligibility: SurfaceLiftEligibility(),
                            locationInWindow: CGPoint(x: 200, y: 640)))
        #expect(driver.splitTargetSlot == .bottom)
        _ = driver.end(cancelled: true, animated: false)
        #expect(deliveries == 0)
        #expect(driver.lastSplitDropIntent == nil)
        #expect(driver.state.phase == .full && host.presentation == .full)
        #expect(driver.arm(SurfaceLiftEligibility(), conversationID: "source"))
        #expect(driver.drag(upwardDistance: 320, eligibility: SurfaceLiftEligibility(),
                            locationInWindow: CGPoint(x: 200, y: 160)))
        driver.invalidate()
        #expect(driver.state.phase == .full && host.presentation == .full)
        #expect(!driver.splitTargetingVisible && driver.splitTargetSlot == nil)
    }

    @Test func splitTargetCanMoveFromTopToLowerPaneCenterAfterActivation() {
        let host = ConversationSurfaceViewController(content: Text("mobile Split target"))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        let driver = SurfaceLiftController()
        driver.bind(host)
        var entries = 0
        var intent: SplitDropIntent?
        driver.onSplitTargetEntry = { entries += 1 }
        driver.configureSplit { value in intent = value; return false }
        #expect(driver.arm(SurfaceLiftEligibility(), conversationID: "source"))
        #expect(driver.drag(upwardDistance: 320, eligibility: SurfaceLiftEligibility(),
                            locationInWindow: CGPoint(x: 200, y: 160)))
        #expect(driver.splitTargetSlot == .top)
        #expect(driver.drag(upwardDistance: 100, eligibility: SurfaceLiftEligibility(),
                            locationInWindow: CGPoint(x: 200, y: 600)))
        #expect(driver.splitTargetSlot == .bottom)
        #expect(entries == 2)
        _ = driver.end(animated: false)
        #expect(intent == SplitDropIntent(conversationID: "source", slot: .bottom))
        #expect(driver.state.phase == .full && host.presentation == .full)
    }

    @Test func acceptedSplitDropDoesNotAnimateTheSourceBackToFull() {
        let host = ConversationSurfaceViewController(content: Text("accepted Split target"))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        let child = host.contentController
        let driver = SurfaceLiftController()
        driver.bind(host)
        var intent: SplitDropIntent?
        driver.configureSplit { value in intent = value; return true }
        #expect(driver.arm(SurfaceLiftEligibility(), conversationID: "source"))
        #expect(driver.drag(upwardDistance: 320, eligibility: SurfaceLiftEligibility(),
                            locationInWindow: CGPoint(x: 200, y: 160)))
        _ = driver.end(animated: false)
        #expect(intent == SplitDropIntent(conversationID: "source", slot: .top))
        #expect(driver.state.phase != .full)
        #expect(host.presentation != .full)
        #expect(host.contentController === child)
        driver.invalidate()
        #expect(host.presentation == .full)
    }

    @Test func finalReleaseSampleOverridesThePreviousSplitTarget() async throws {
        let host = ConversationSurfaceViewController(content: Text("final Split release"))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        let driver = SurfaceLiftController()
        driver.bind(host)
        var delivered: SplitDropIntent?
        driver.configureSplit { intent in delivered = intent; return false }
        #expect(driver.arm(SurfaceLiftEligibility(), conversationID: "source"))
        #expect(driver.drag(upwardDistance: 320, eligibility: SurfaceLiftEligibility(),
                            locationInWindow: CGPoint(x: 200, y: 160)))
        #expect(driver.splitTargetSlot == .top)
        ComposerLiftInteraction.finish(driver: driver, origin: CGPoint(x: 200, y: 480),
            point: CGPoint(x: 200, y: 600), eligibility: SurfaceLiftEligibility(), cancelled: false)
        #expect(delivered == SplitDropIntent(conversationID: "source", slot: .bottom))
        #expect(driver.state.pendingSettlement?.destination == .full)
        try await Task.sleep(for: .milliseconds(450))
        #expect(driver.state.phase == .full && host.presentation == .full)
    }

    @Test func conversationChangeCancelsCapturedSplitSource() {
        let host = ConversationSurfaceViewController(content: Text("obsolete Split source"))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        let driver = SurfaceLiftController()
        driver.bind(host)
        var deliveries = 0
        driver.configureSplit { _ in deliveries += 1; return true }
        #expect(driver.arm(SurfaceLiftEligibility(), conversationID: "old"))
        #expect(driver.drag(upwardDistance: 320, eligibility: SurfaceLiftEligibility(),
                            locationInWindow: CGPoint(x: 200, y: 160)))
        driver.resetForConversationChange()
        #expect(driver.end(animated: false) == nil)
        #expect(deliveries == 0 && driver.lastSplitDropIntent == nil)
        #expect(driver.state.phase == .full && host.presentation == .full)
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

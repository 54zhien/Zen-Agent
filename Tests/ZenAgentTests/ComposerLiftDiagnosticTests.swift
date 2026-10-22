import Darwin
import SwiftUI
import Testing
import UIKit
@testable import ZenAgent

@MainActor
private final class DiagnosticLongPressSample: UILongPressGestureRecognizer {
    var sample: UIGestureRecognizer.State = .possible
    var point = CGPoint(x: 180, y: 700)
    override var state: UIGestureRecognizer.State {
        get { sample }
        set { sample = newValue }
    }
    override func location(in view: UIView?) -> CGPoint { point }
}

@Suite("Composer Lift diagnostic lifetime", .serialized)
@MainActor
struct ComposerLiftDiagnosticTests {
    @Test("accepted long press grows the Composer contents and cancellation restores them",
          arguments: [UIUserInterfaceStyle.light, .dark])
    func acceptedPressHasVisibleFeedback(style: UIUserInterfaceStyle) throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKey = scene.windows.first { $0.isKeyWindow }
        let host = ConversationSurfaceViewController(content: Color.clear)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = style
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousKey?.makeKey() }
        host.view.layoutIfNeeded()
        let surface = UIView(frame: CGRect(x: 40, y: 680, width: 300, height: 70))
        surface.backgroundColor = .systemBackground
        surface.cornerConfiguration = .corners(radius: .containerConcentric(minimum: 22))
        let editor = UITextView()
        host.view.addSubview(surface)
        let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        glass.frame = surface.bounds
        surface.addSubview(glass)
        let label = UILabel(frame: surface.bounds.insetBy(dx: 24, dy: 12))
        label.text = "说点什么吧"
        label.textColor = .secondaryLabel
        surface.addSubview(label)
        surface.addSubview(editor)
        try #require(surface.traitCollection.userInterfaceStyle == style)
        // Resolve after attachment so the recorded fixture uses its actual
        // inherited appearance even before UIKit refreshes dynamic layer colors.
        let background = UIColor.systemBackground.resolvedColor(with: surface.traitCollection)
        surface.backgroundColor = background
        host.view.backgroundColor = background
        host.surfaceView.backgroundColor = background
        let driver = SurfaceLiftController()
        driver.bind(host)
        defer { driver.unbind(host) }
        let input = ComposerLiftInteraction(surface: surface, editor: editor,
            nativeInput: { SurfaceLiftEligibility() })
        input.configure(.init(driver: driver, conversationID: "feedback", eligibility: { $0 }))
        let originalFrame = surface.frame
        let originalBounds = surface.bounds
        func capture(_ phase: String) throws {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 340, height: 110))
            var complete = false
            let picture = renderer.image { context in
                UIColor.systemBackground.resolvedColor(with: surface.traitCollection).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 340, height: 110))
                // Keep the enlarged glass and its halo in the native capture.
                complete = host.view.drawHierarchy(in: CGRect(x: 20 - surface.frame.minX,
                    y: 20 - surface.frame.minY, width: host.view.bounds.width,
                    height: host.view.bounds.height), afterScreenUpdates: true)
            }
            try #require(complete)
            let bytes = try #require(picture.pngData())
            Attachment.record(bytes, named: "Composer-feedback-\(style == .dark ? "dark" : "light")-\(phase).png")
        }
        try capture("resting")
        let sample = DiagnosticLongPressSample()
        sample.sample = .began
        _ = input.perform(NSSelectorFromString("gestureChanged:"), with: sample)
        try #require(driver.state.phase == .armed)
        let readyTransform = surface.layer.sublayerTransform
        #expect(readyTransform.m11 > 1 && readyTransform.m22 > 1)
        #expect(surface.layer.sublayers?.contains { $0.name == "zen-composer-lift-ready" } != true)
        #expect(surface.transform == .identity, "feedback must not invalidate native Composer layout readiness")
        #expect(surface.frame == originalFrame && surface.bounds == originalBounds)
        let animation = try #require(input.feedbackAnimatorForTesting)
        animation.pauseAnimation()
        animation.fractionComplete = 0.25
        CATransaction.flush()
        try capture("armed")
        let visibleScale = try #require(surface.layer.presentation()?.sublayerTransform)
        #expect(visibleScale.m11 > 1 && visibleScale.m11 < readyTransform.m11,
                "The actual backing tree must render an intermediate spring scale")
        #expect(visibleScale.m22 > 1 && visibleScale.m22 < readyTransform.m22)
        sample.sample = .cancelled
        _ = input.perform(NSSelectorFromString("gestureChanged:"), with: sample)
        let returning = try #require(input.feedbackAnimatorForTesting)
        returning.stopAnimation(false)
        returning.finishAnimation(at: .end)
        CATransaction.flush()
        #expect(driver.state.phase == .full)
        #expect(CATransform3DEqualToTransform(surface.layer.sublayerTransform, CATransform3DIdentity))
        #expect(surface.frame == originalFrame && surface.bounds == originalBounds)
        try capture("cancelled")
    }

    @Test("native long press carries horizontal and vertical movement into the retained page")
    func nativeGestureTransportsBothDisplacementAxes() throws {
        let host = ConversationSurfaceViewController(content: Color.clear)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        let surface = UIView(frame: CGRect(x: 40, y: 680, width: 300, height: 70))
        let editor = UITextView()
        host.view.addSubview(surface)
        surface.addSubview(editor)

        let driver = SurfaceLiftController()
        driver.bind(host)
        defer { driver.unbind(host) }
        let input = ComposerLiftInteraction(surface: surface, editor: editor,
            nativeInput: { SurfaceLiftEligibility() })
        input.configure(.init(driver: driver, conversationID: "two-axis", eligibility: { $0 }))

        let sample = DiagnosticLongPressSample()
        let action = NSSelectorFromString("gestureChanged:")
        sample.point = CGPoint(x: 180, y: 700)
        sample.sample = .began
        _ = input.perform(action, with: sample)
        try #require(driver.state.phase == .armed)

        sample.point = CGPoint(x: 222, y: 580)
        sample.sample = .changed
        _ = input.perform(action, with: sample)
        #expect(driver.state.phase == .lifting)
        // Both axes are resisted so the shrinking page remains inside the screen.
        #expect(host.presentation.translation.width > 0)
        #expect(host.presentation.translation.width < 42)
        let verticalLimit = (host.view.bounds.height - host.view.safeAreaInsets.top
            - host.view.safeAreaInsets.bottom) * 0.12
        #expect(host.presentation.translation.height < 0)
        #expect(abs(host.presentation.translation.height) < min(120, verticalLimit))
        #expect(host.presentation.clipFraction == CGSize(width: 1, height: 1))
        #expect(abs(driver.state.progress - 108.0 / 168.0) < 0.000001)

        input.cancelForDetachment()
        #expect(driver.state.phase == .full)
        #expect(CATransform3DEqualToTransform(surface.layer.sublayerTransform, CATransform3DIdentity))
    }

    @Test("the original driver retains terminal evidence after native transport loses its attachment",
          arguments: ["window", "configuration", "replacement"])
    func terminalReceiptSurvivesTransportLoss(boundary: String) throws {
        let key = "ZEN_PREVIEW_HANDOFF_UI_TEST"
        let previous = ProcessInfo.processInfo.environment[key]
        setenv(key, "1", 1)
        defer {
            if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
        }

        let host = ConversationSurfaceViewController(content: Color.clear)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        let surface = UIView(frame: CGRect(x: 40, y: 680, width: 300, height: 70))
        let editor = UITextView()
        host.view.addSubview(surface)
        surface.addSubview(editor)
        let driver = SurfaceLiftController()
        driver.bind(host)
        defer { driver.unbind(host) }
        let replacement = SurfaceLiftController()
        let input = ComposerLiftInteraction(surface: surface, editor: editor,
            nativeInput: { SurfaceLiftEligibility() })
        input.configure(.init(driver: driver, conversationID: "original", eligibility: { $0 }))

        // Exercise the production target/action boundary. This controls the
        // callback sample, not gesture recognition or a successful Surface state.
        let sample = DiagnosticLongPressSample()
        let action = NSSelectorFromString("gestureChanged:")
        sample.sample = .began
        _ = input.perform(action, with: sample)
        try #require(driver.state.phase == .armed)
        if boundary == "window" {
            surface.removeFromSuperview()
            try #require(surface.window == nil)
        } else if boundary == "configuration" {
            input.configure(nil)
        } else {
            input.configure(.init(driver: replacement, conversationID: "replacement", eligibility: { $0 }))
        }
        // Teardown can destroy the transport without delivering a final callback.
        #expect(driver.lastNativeLiftReceipt.contains("began;"))
        sample.sample = .cancelled
        _ = input.perform(action, with: sample)

        #expect(driver.lastNativeLiftReceipt.contains("began;"))
        #expect(driver.lastNativeLiftReceipt.contains("terminal=\(UIGestureRecognizer.State.cancelled.rawValue)"))
        #expect(driver.lastNativeLiftReceipt.contains("peers=[]"))
        #expect(replacement.lastNativeLiftReceipt.isEmpty,
                "a cancelled old gesture must not become a replacement owner's receipt")
    }
}

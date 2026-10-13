import Darwin
import SwiftUI
import Testing
import UIKit
@testable import ZenAgent

@MainActor
private final class DiagnosticLongPressSample: UILongPressGestureRecognizer {
    var sample: UIGestureRecognizer.State = .possible
    override var state: UIGestureRecognizer.State {
        get { sample }
        set { sample = newValue }
    }
    override func location(in view: UIView?) -> CGPoint { CGPoint(x: 180, y: 700) }
}

@Suite("Composer Lift diagnostic lifetime", .serialized)
@MainActor
struct ComposerLiftDiagnosticTests {
    @Test("accepted long press visibly arms the Composer and cancellation removes its animation")
    func acceptedPressHasVisibleFeedback() throws {
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
        input.configure(.init(driver: driver, conversationID: "feedback", eligibility: { $0 }))
        let sample = DiagnosticLongPressSample()
        sample.sample = .began
        _ = input.perform(NSSelectorFromString("gestureChanged:"), with: sample)
        try #require(driver.state.phase == .armed)
        let feedback = try #require(surface.layer.sublayers?.first { $0.name == "zen-composer-lift-ready" })
        #expect(feedback.opacity > 0)
        #expect(!(feedback.animationKeys() ?? []).isEmpty)
        #expect(surface.transform == .identity, "feedback must not invalidate native Composer layout readiness")
        sample.sample = .cancelled
        _ = input.perform(NSSelectorFromString("gestureChanged:"), with: sample)
        #expect(driver.state.phase == .full)
        #expect(feedback.opacity == 0 && (feedback.animationKeys() ?? []).isEmpty)
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

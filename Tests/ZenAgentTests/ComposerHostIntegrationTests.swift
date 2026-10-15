import Testing
import UIKit
import SwiftUI

@testable import ZenAgent

@MainActor
@Suite("Composer host wiring")
struct ComposerHostIntegrationTests {
    @Test("Sidebar admits both native stable Composer phases", arguments: [ComposerPresentationState.resting, .editing])
    func sidebarAcceptsStableNativePhase(state: ComposerPresentationState) throws {
        let surface = ConversationSurfaceViewController(content: Color.clear, request: .full)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = surface
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        surface.view.layoutIfNeeded()
        let content = try #require(surface.children.first?.view)
        let composer = ComposerHostView(frame: .zero)
        // Establish the actual stable phase without introducing a test animator
        // completion or claiming a simulated keyboard transition.
        composer.configure(configuration(text: "", state: state))
        content.addSubview(composer)
        composer.frame = content.bounds
        composer.layoutIfNeeded()
        #expect(surface.allowsSidebarInput)
        if state == .editing { #expect(!composer.nativeLiftInput.allowsLift) }
    }

    @Test("editorIdentitySurvivesMorphAndPlaceholderSharesOrigin")
    func editorIdentitySurvivesMorph() {
        let (window, host) = installedHost()
        _ = window
        let editor = host.editor
        host.configure(configuration(state: .resting))
        host.layoutIfNeeded()
        #expect(abs(host.keyboardGap - 6) < 1)
        #expect(host.hitTest(CGPoint(x: host.bounds.midX, y: 200), with: nil) == nil)
        #expect(host.hitTest(CGPoint(x: host.surfaceFrame.midX,
                                     y: host.surfaceFrame.midY), with: nil) != nil)
        #expect(host.editor === editor)
        #expect(abs(host.editor.bounds.width - host.previewViewportWidth) < 1)
        #expect(host.placeholder.superview === editor.superview)
        let restingOpacity = host.placeholder.alpha
        #expect(restingOpacity == 1)
        host.configure(configuration(state: .editing))
        #expect(host.placeholder.alpha < restingOpacity)
        host.configure(configuration(state: .resting))
        #expect(host.editor === editor)
    }

    @Test("empty composer placeholder sits beside the caret in the shared viewport")
    func emptyPlaceholderFollowsCaret() {
        let (window, host) = installedHost(initialState: .editing)
        _ = window
        host.configure(configuration(text: "", state: .editing))
        host.layoutIfNeeded()
        #expect(host.placeholder.superview != nil)
        guard let viewport = host.placeholder.superview else { return }
        let caret = host.editor.convert(
            host.editor.caretRect(for: host.editor.beginningOfDocument), to: viewport
        )
        #expect(host.placeholder.text == "说点什么吧")
        #expect(host.editor.tintColor == .label)
        #expect(host.placeholder.frame.minX > caret.maxX)
        #expect(host.placeholder.frame.minX - caret.maxX <= 2)
        #expect(abs(host.placeholder.frame.midY - caret.midY) < 2)
        #expect(host.placeholder.frame.intersects(viewport.bounds))
        #expect(abs(host.placeholder.alpha - 0.62) < 0.001)
    }

    @Test("primary action binds to latest callback exactly once")
    func primaryCallbackUsesLatestConfiguration() {
        let (window, host) = installedHost()
        _ = window
        var oldCount = 0
        var newCount = 0
        host.configure(configuration(onSend: { oldCount += 1 }))
        host.configure(configuration(onSend: { newCount += 1 }))
        let button = findButton(in: host, id: "conversation-composer-send")
        #expect(button != nil)
        button?.sendActions(for: .touchUpInside)
        #expect(oldCount == 0)
        #expect(newCount == 1)
    }

    @Test("readiness growth preserves the native Composer settled measurement")
    func readinessGrowthPreservesNativeSettledMeasurement() throws {
        let (window, host) = installedHost()
        defer { window.isHidden = true }
        let surface = try #require(host.subviews.first)
        let originalFrame = surface.frame
        let originalBounds = surface.bounds
        #expect(host.nativeLiftInput.composerSettled)

        let feedback = ComposerLiftFeedback(surface: surface)
        feedback.setReady(true)
        #expect(surface.layer.sublayerTransform.m11 > 1)
        #expect(surface.frame == originalFrame && surface.bounds == originalBounds)
        #expect(host.nativeLiftInput.composerSettled)

        feedback.setReady(false)
        #expect(CATransform3DEqualToTransform(surface.layer.sublayerTransform, CATransform3DIdentity))
        #expect(surface.frame == originalFrame && surface.bounds == originalBounds)
        #expect(host.nativeLiftInput.composerSettled)
    }

    @Test("Composer action buttons keep clear 44-point targets and readable icons")
    func actionButtonsKeepClearTargetsAndReadableIcons() throws {
        let (window, host) = installedHost()
        defer { window.isHidden = true }
        host.configure(configuration(showsPlus: true))
        host.layoutIfNeeded()

        let plus = try #require(findButton(in: host, id: "conversation-composer-plus"))
        let primary = try #require(findButton(in: host, id: "conversation-composer-send"))
        let buttons = [plus, primary]
        for button in buttons {
            #expect(!button.isHidden)
            #expect(button.bounds.width >= 44 && button.bounds.height >= 44)
            #expect(button.backgroundColor == .clear)
            #expect(button.tintColor == .label)
            #expect(button.currentImage != nil)
            #expect(button.point(inside: CGPoint(x: button.bounds.midX, y: button.bounds.midY), with: nil))
        }
    }

    @Test("Composer bottom fade stays behind the input and ends at the active viewport bottom")
    func bottomFadeFollowsActiveViewportBottom() throws {
        let (window, host) = installedHost()
        defer { window.isHidden = true }
        host.layoutIfNeeded()

        let fadeLayer = host.layer.sublayers?.first { $0.name == "zen-composer-bottom-fade" }
            as? ComposerBottomFadeLayer
        let fade = try #require(fadeLayer)
        let surface = try #require(host.subviews.first)
        #expect(fade.superlayer === host.layer)
        #expect(host.layer.sublayers?.first === fade)
        #expect(fade.frame.minY < surface.frame.minY)
        #expect(abs(fade.frame.maxY - host.bounds.maxY) < 0.5)
        #expect(abs(fade.frame.width - host.bounds.width) < 0.5)

        let keyboardBottom = host.bounds.maxY - 240
        fade.update(bounds: host.bounds, composerFrame: CGRect(x: 0, y: 500, width: host.bounds.width, height: 64),
                    bottom: keyboardBottom, traits: host.traitCollection)
        #expect(abs(fade.frame.maxY - keyboardBottom) < 0.5)
        #expect(fade.frame.minY < fade.frame.maxY)
    }

    @Test("Bottom fade covers the owning card through its home safe area",
          arguments: [UIUserInterfaceStyle.light, .dark], [0, 1, 2])
    func bottomFadeCoversNativeCard(style: UIUserInterfaceStyle, pane: Int) throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let root = UIViewController()
        root.overrideUserInterfaceStyle = style
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }

        let owner = ConversationSurfaceViewController(content: Color.clear, request: .full)
        root.addChild(owner)
        root.view.addSubview(owner.view)
        let cardFrame = [CGRect(x: 0, y: 0, width: 402, height: 874),
                         CGRect(x: 0, y: 0, width: 402, height: 400),
                         CGRect(x: 0, y: 424, width: 402, height: 450)][pane]
        owner.view.frame = cardFrame
        owner.didMove(toParent: root)
        owner.view.layoutIfNeeded()
        let card = owner.surfaceView
        let page = UIColor.systemBackground.resolvedColor(with: card.traitCollection)
        card.backgroundColor = page
        // Contrasting native content continues behind the input to the card edge.
        let content = UIView(frame: card.bounds)
        content.backgroundColor = UIColor.label.resolvedColor(with: card.traitCollection)
        card.addSubview(content)
        let top: CGFloat = pane == 2 ? 0 : 62
        let home: CGFloat = pane == 1 ? 0 : 34
        let host = ComposerHostView(frame: CGRect(x: 0, y: top, width: 402,
                                                  height: card.bounds.height - top - home))
        card.addSubview(host)
        host.configure(configuration(text: "", state: .resting))
        host.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: card.bounds.size, format: format).image { context in
            card.layer.render(in: context.cgContext)
        }
        let actual = try bottomPixel(image, at: CGPoint(x: 201, y: card.bounds.maxY - 2))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        try #require(page.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        #expect(abs(actual[0] - red) < 0.05 && abs(actual[1] - green) < 0.05
                && abs(actual[2] - blue) < 0.05,
                "The page-colored fade must cover content below the safe-area-sized Composer host")

        let fade = try #require(host.layer.sublayers?.first { $0.name == "zen-composer-bottom-fade" })
        let end = host.convert(CGPoint(x: 201, y: fade.frame.maxY), to: card)
        #expect(abs(end.y - card.bounds.maxY) < 0.5,
                "The upper Split must stop at its own edge; the lower and Full must include home safe area")
        card.transform = CGAffineTransform(translationX: 35, y: -47).scaledBy(x: 0.8, y: 0.8)
        host.setNeedsLayout()
        host.layoutIfNeeded()
        let floatingEnd = host.convert(CGPoint(x: 201, y: fade.frame.maxY), to: card)
        #expect(abs(floatingEnd.y - card.bounds.maxY) < 0.5)
    }

    private func bottomPixel(_ image: UIImage, at point: CGPoint) throws -> [CGFloat] {
        let original = try #require(image.cgImage)
        let patch = try #require(original.cropping(to: CGRect(origin: point, size: CGSize(width: 1, height: 1))))
        var bytes = [UInt8](repeating: 0, count: 4)
        let drawn = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.draw(patch, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        try #require(drawn)
        return bytes.prefix(3).map { CGFloat($0) / 255 }
    }

    @Test("text updates retarget an in-flight morph")
    func textChangeDuringMorphRetargets() {
        let (window, host) = installedHost()
        _ = window
        host.configure(configuration(state: .editing))
        let firstGeneration = host.motionGeneration
        host.configure(configuration(text: "正在组词", state: .editing))
        #expect(host.motionGeneration > firstGeneration)
    }

    @Test("removing the final quote releases timeline clearance")
    func removingFinalQuoteReleasesClearance() {
        let (window, host) = installedHost(initialState: .editing)
        _ = window
        let quote = QuoteReference(
            id: "quote", source: QuoteSourceLocator(
                sourceConversationID: "conversation", sourceMessageID: "message",
                sourcePartID: "part", range: QuoteTextRange(utf16Start: 0, utf16Length: 2)
            ), snapshot: "引用", createdAt: Date()
        )
        host.configure(configuration(state: .editing, references: [quote]))
        let withQuote = host.reportedClearance
        host.configure(configuration(state: .editing))
        #expect(host.reportedClearance < withQuote)
    }

    @Test("timeline dismissal excludes message content")
    func timelineTapOnlyDismissesOnBlankSpace() {
        let frames = ["turn": CGRect(x: 20, y: 100, width: 350, height: 120)]
        #expect(!ConversationTimelineView.isBlankTap(CGPoint(x: 80, y: 140),
                                                      turnFrames: frames))
        #expect(ConversationTimelineView.isBlankTap(CGPoint(x: 80, y: 300),
                                                    turnFrames: frames))
    }

    @Test("Lift reads native composition and keyboard transition separately")
    func nativeLiftReadinessDoesNotInferSafetyFromZeroKeyboardHeight() {
        let (window, host) = installedHost()
        defer { host.editor.resignFirstResponder(); window.isHidden = true }
        let editor = host.editor
        host.configure(configuration(state: .editing))
        #expect(host.nativeLiftInput.isEditing)
        #expect(!host.nativeLiftInput.allowsLift)
        host.configure(configuration(state: .resting))
        editor.setMarkedText("候选文字", selectedRange: NSRange(location: 2, length: 0))
        #expect(editor.markedTextRange != nil)
        #expect(host.nativeLiftInput.hasMarkedText)
        #expect(!host.nativeLiftInput.allowsLift)
        #expect(host.editor === editor)
        editor.unmarkText()
        let info: [AnyHashable: Any] = [
            UIResponder.keyboardFrameEndUserInfoKey: CGRect(x: 0, y: window.bounds.maxY,
                width: window.bounds.width, height: 300),
            UIResponder.keyboardAnimationDurationUserInfoKey: NSNumber(value: 0.2),
            UIResponder.keyboardAnimationCurveUserInfoKey: NSNumber(value: 0),
        ]
        NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification,
                                        object: window.screen, userInfo: info)
        #expect(host.nativeLiftInput.keyboardTransitioning)
        #expect(!host.nativeLiftInput.allowsLift)
        NotificationCenter.default.post(name: UIResponder.keyboardDidChangeFrameNotification,
                                        object: window.screen, userInfo: info)
        #expect(!host.nativeLiftInput.keyboardTransitioning)
    }

    @Test("teardown releases the native Lift recognizer and editor")
    func teardownReleasesNativeLiftTransport() async throws {
        weak var weakHost: ComposerHostView?
        weak var weakEditor: UITextView?
        weak var weakGesture: UILongPressGestureRecognizer?
        func liftGesture(in view: UIView) -> UILongPressGestureRecognizer? {
            if let gesture = view.gestureRecognizers?.compactMap({ $0 as? UILongPressGestureRecognizer }).first {
                return gesture
            }
            return view.subviews.lazy.compactMap { liftGesture(in: $0) }.first
        }
        autoreleasepool {
            let host = ComposerHostView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            var config = configuration()
            config.liftInteraction = .init(driver: SurfaceLiftController(),
                                           conversationID: "test-conversation", eligibility: { $0 })
            host.configure(config)
            weakHost = host
            weakEditor = host.editor
            weakGesture = liftGesture(in: host)
            #expect(weakGesture != nil)
        }
        // Let queued UIKit/hosting work finish; a retained transport must still
        // fail the same weak-reference checks after this bounded drain.
        for _ in 0..<10 where weakHost != nil || weakEditor != nil || weakGesture != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(weakHost == nil)
        #expect(weakEditor == nil)
        #expect(weakGesture == nil)
    }

    private func installedHost(
        initialState: ComposerPresentationState = .resting
    ) -> (UIWindow, ComposerHostView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let host = ComposerHostView(frame: controller.view.bounds)
        controller.view.addSubview(host)
        host.configure(configuration(state: initialState))
        host.layoutIfNeeded()
        return (window, host)
    }

    private func configuration(
        text: String = "hello",
        state: ComposerPresentationState = .resting,
        showsPlus: Bool = false,
        references: [QuoteReference] = [],
        onSend: @escaping () -> Void = {}
    ) -> ComposerHostView.Configuration {
        ComposerHostView.Configuration(
            text: text, selection: ComposerSelection(range: 0..<0),
            state: state, collapseProgress: .expanded,
            font: .systemFont(ofSize: 16), showsPlus: showsPlus,
            primary: .send(enabled: true), models: [],
            selectedModelID: ModelID(rawValue: "test-model"),
            errorMessage: nil, references: references,
            onRemoveQuote: { _ in }, onAcceptQuote: { _ in }, onQuotePhase: { _ in },
            onText: { _, _, _ in }, onFocus: { _ in }, onSend: onSend,
            onStop: {}, onModel: { _ in }, onHeightChanged: { _ in }
        )
    }

    private func findButton(in view: UIView, id: String) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityIdentifier == id { return button }
        for child in view.subviews {
            if let button = findButton(in: child, id: id) { return button }
        }
        return nil
    }
}

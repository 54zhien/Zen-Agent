import Testing
import UIKit

@testable import ZenAgent

@MainActor
@Suite("Composer host wiring")
struct ComposerHostIntegrationTests {
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
        #expect(restingOpacity < 1)
        host.configure(configuration(state: .editing))
        #expect(host.placeholder.alpha > restingOpacity)
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
        #expect(host.editor.tintColor == .black)
        #expect(host.placeholder.frame.minX > caret.maxX)
        #expect(host.placeholder.frame.minX - caret.maxX <= 2)
        #expect(abs(host.placeholder.frame.midY - caret.midY) < 2)
        #expect(host.placeholder.frame.intersects(viewport.bounds))
        #expect(host.placeholder.alpha == 1)
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
        references: [QuoteReference] = [],
        onSend: @escaping () -> Void = {}
    ) -> ComposerHostView.Configuration {
        ComposerHostView.Configuration(
            text: text, selection: ComposerSelection(range: 0..<0),
            state: state, collapseProgress: .expanded,
            font: .systemFont(ofSize: 16), showsPlus: false,
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

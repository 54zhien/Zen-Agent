import Testing
import UIKit

@testable import ZenAgent

@MainActor
@Suite("Composer exit layout")
struct ComposerExitLayoutTests {
    @Test("exit intent keeps multiline layout until the visible transition settles")
    func exitKeepsMultilineUntilSettled() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let host = ComposerHostView(frame: controller.view.bounds)
        controller.view.addSubview(host)
        host.configure(configuration(.resting))
        host.layoutIfNeeded()

        host.configure(configuration(.editing))
        try await Task.sleep(for: .milliseconds(350))
        #expect(host.editor.textContainer.maximumNumberOfLines == 0)

        host.configure(configuration(.resting))
        #expect(host.editor.textContainer.maximumNumberOfLines == 0)
        _ = window
    }

    @Test("long text preserves the visible scroll position during collapse")
    func longTextDoesNotJumpBeforeSettle() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let host = ComposerHostView(frame: controller.view.bounds)
        controller.view.addSubview(host)
        let text = Array(repeating: "一段足够长的中文输入内容", count: 80).joined(separator: "\n")
        host.configure(configuration(.resting, text: text))
        host.layoutIfNeeded()
        host.configure(configuration(.editing, text: text))
        try await Task.sleep(for: .milliseconds(350))
        host.editor.layoutIfNeeded()
        #expect(host.editor.isScrollEnabled)
        host.editor.setContentOffset(CGPoint(x: 0, y: 100), animated: false)
        let before = host.editor.contentOffset.y
        #expect(before > 1)

        host.configure(configuration(.resting, text: text))
        #expect(abs(host.editor.contentOffset.y - before) < 1)
        _ = window
    }

    private func configuration(_ state: ComposerPresentationState,
                               text: String = "first line\nsecond line") -> ComposerHostView.Configuration {
        ComposerHostView.Configuration(
            text: text,
            selection: ComposerSelection(range: 0..<0),
            state: state, collapseProgress: .expanded,
            font: .systemFont(ofSize: 16), showsPlus: false,
            primary: .none, models: [], selectedModelID: ModelID(rawValue: "test-model"),
            errorMessage: nil, references: [],
            onRemoveQuote: { _ in }, onAcceptQuote: { _ in }, onQuotePhase: { _ in },
            onText: { _, _, _ in }, onFocus: { _ in }, onSend: {}, onStop: {},
            onModel: { _ in }, onHeightChanged: { _ in }
        )
    }
}

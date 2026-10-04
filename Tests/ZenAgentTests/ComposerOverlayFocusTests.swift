import Testing
import UIKit
@testable import ZenAgent

@Suite("Native overlay responder restoration")
@MainActor
struct ComposerOverlayFocusTests {
    @Test func restorationWaitsForInputAndKeepsTheActualEditor() throws {
        let (window, host) = installedHost()
        defer { host.editor.resignFirstResponder(); window.isHidden = true; window.rootViewController = nil }
        let editor = host.editor
        #expect(editor.becomeFirstResponder())
        let token = try #require(host.captureOverlayFocus(ownerIsCurrent: { true }))
        host.setWorkspaceInputSuppressed(true)
        #expect(!editor.isFirstResponder)
        token.restore()
        #expect(!editor.isFirstResponder)
        host.setWorkspaceInputSuppressed(false)
        host.requestFocus(false)
        host.consumeOverlayFocusIfReady()
        #expect(editor.isFirstResponder)
        #expect(host.editor === editor)
        #expect(editor.text == "same draft")
    }

    @Test func ownerReplacementInvalidatesAQueuedRestore() throws {
        let (window, host) = installedHost()
        defer { host.editor.resignFirstResponder(); window.isHidden = true; window.rootViewController = nil }
        var sameOwner = true
        #expect(host.editor.becomeFirstResponder())
        let token = try #require(host.captureOverlayFocus(ownerIsCurrent: { sameOwner }))
        host.setWorkspaceInputSuppressed(true)
        token.restore()
        sameOwner = false
        host.setWorkspaceInputSuppressed(false)
        host.consumeOverlayFocusIfReady()
        #expect(token.cancelled)
        #expect(!host.editor.isFirstResponder)
    }

    private func installedHost() -> (UIWindow, ComposerHostView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIViewController()
        window.rootViewController = root; window.makeKeyAndVisible()
        let host = ComposerHostView(frame: root.view.bounds)
        root.view.addSubview(host)
        host.configure(.init(text: "same draft", selection: .init(range: 0..<0), state: .resting,
            collapseProgress: .expanded, font: .systemFont(ofSize: 16), showsPlus: false,
            primary: .send(enabled: false), models: [], selectedModelID: nil, errorMessage: nil,
            references: [], onRemoveQuote: { _ in }, onAcceptQuote: { _ in }, onQuotePhase: { _ in },
            onText: { _, _, _ in }, onFocus: { _ in }, onSend: {}, onStop: {}, onModel: { _ in },
            onHeightChanged: { _ in }))
        host.layoutIfNeeded()
        return (window, host)
    }
}

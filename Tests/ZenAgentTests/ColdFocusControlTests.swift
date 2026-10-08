import Testing
import UIKit
@testable import ZenAgent

@Suite("Cold native focus controls", .serialized)
@MainActor
struct ColdFocusControlTests {
    @Test func plainUIKitOutgoingFirstKeepsIncomingFocus() async throws {
        try await transfer(usingComposerHost: false)
    }
    @Test func composerHostOutgoingFirstKeepsIncomingFocus() async throws {
        try await transfer(usingComposerHost: true)
    }
    @Test func plainUIKitOnApplicationWindowKeepsIncomingFocus() async throws {
        try await transfer(usingComposerHost: false, usingApplicationWindow: true)
    }

    private func transfer(usingComposerHost: Bool, usingApplicationWindow: Bool = false) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window: UIWindow
        if usingApplicationWindow { window = try #require(previous) }
        else { window = UIWindow(windowScene: scene) }
        let root = ColdFocusControlRoot()
        if !usingApplicationWindow {
            window.rootViewController = root; window.makeKeyAndVisible()
        }
        defer {
            if !usingApplicationWindow {
                window.endEditing(true); window.isHidden = true
                window.rootViewController = nil; previous?.makeKeyAndVisible()
            }
        }
        if !usingApplicationWindow {
            for _ in 0..<40 where !root.didAppear { try await Task.sleep(for: .milliseconds(25)) }
            try #require(root.didAppear)
        }
        try #require(window.isKeyWindow)
        ComposerHostView.focusDiagnostic = { print("COLD_HOST \(Date().timeIntervalSince1970) \($0)") }
        defer { ComposerHostView.focusDiagnostic = nil }
        let aHost = usingComposerHost ? ComposerHostView(frame: window.bounds) : nil
        let bHost = usingComposerHost ? ComposerHostView(frame: window.bounds) : nil
        let editorFrame = CGRect(x: 28, y: 100, width: window.bounds.width - 56, height: 58)
        let a = aHost?.editor ?? UITextView(frame: editorFrame)
        let b = bHost?.editor ?? UITextView(frame: editorFrame)
        let aView: UIView = aHost.map { $0 as UIView } ?? a
        let bView: UIView = bHost.map { $0 as UIView } ?? b
        a.text = "a"; b.text = "b"
        a.font = .systemFont(ofSize: 16); b.font = .systemFont(ofSize: 16)
        aHost?.configure(configuration(text: "a", editing: true))
        bHost?.configure(configuration(text: "b", editing: false))
        let container = UIView(frame: window.bounds)
        window.addSubview(container); container.addSubview(aView)
        defer { a.resignFirstResponder(); b.resignFirstResponder(); container.removeFromSuperview() }
        aView.layoutIfNeeded()
        func report(_ phase: String) {
            print("COLD_CONTROL \(Date().timeIntervalSince1970) host=\(usingComposerHost) applicationWindow=\(usingApplicationWindow) phase=\(phase) a=\(a.isFirstResponder) b=\(b.isFirstResponder) key=\(window.isKeyWindow) aAttached=\(a.window === window) bAttached=\(b.window === window)")
        }
        report("before outgoing focus")
        if let aHost { aHost.requestFocus(true) } else { _ = a.becomeFirstResponder() }
        report("after outgoing focus")
        try await Task.sleep(for: .milliseconds(250))
        #expect(a.isFirstResponder)
        aHost?.configure(configuration(text: "a", editing: false))
        if let aHost { aHost.requestFocus(false) } else { _ = a.resignFirstResponder() }
        report("outgoing resigned")
        bHost?.configure(configuration(text: "b", editing: true))
        container.addSubview(bView); bView.layoutIfNeeded()
        if let bHost { bHost.requestFocus(true) } else { _ = b.becomeFirstResponder() }
        aView.removeFromSuperview()
        report("incoming immediate")
        #expect(b.isFirstResponder)
        try await Task.sleep(for: .milliseconds(250))
        report("incoming settled")
        #expect(b.isFirstResponder, "cold transfer must retain the incoming native responder")
        #expect(!a.isFirstResponder)
        #expect(a.text == "a" && b.text == "b")
    }

    private func configuration(text: String, editing: Bool) -> ComposerHostView.Configuration {
        .init(text: text, selection: ComposerSelection(range: 0..<0),
            state: editing ? .editing : .resting, collapseProgress: .expanded,
            font: .systemFont(ofSize: 16), showsPlus: false, primary: .send(enabled: true),
            models: [], selectedModelID: nil, errorMessage: nil, references: [],
            onRemoveQuote: { _ in }, onAcceptQuote: { _ in }, onQuotePhase: { _ in },
            onText: { _, _, _ in }, onFocus: { print("COLD_HOST callback focus=\($0)") },
            onSend: {}, onStop: {}, onModel: { _ in }, onHeightChanged: { _ in })
    }
}

@MainActor
private final class ColdFocusControlRoot: UIViewController {
    private(set) var didAppear = false
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        didAppear = true
    }
}

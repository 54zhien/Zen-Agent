import Testing
import UIKit
import SwiftUI
import Observation
@testable import ZenAgent

@Suite("Native overlay responder restoration")
@MainActor
struct ComposerOverlayFocusTests {
    @Test("teardown cancels an unacknowledged close before another field can deliver it")
    func teardownCancelsPendingQueryClose() {
        let (window, _) = installedHost()
        defer { window.isHidden = true; window.rootViewController = nil }
        let focus = SearchQueryFocus()
        let query = SearchQueryTextField(focus: focus)
        query.frame = CGRect(x: 20, y: 100, width: 300, height: 44)
        window.rootViewController?.view.addSubview(query)
        #expect(query.becomeFirstResponder())
        // Exercise a genuinely missing UIKit delegate receipt, rather than
        // inserting a fake delayed close into the production focus owner.
        query.delegate = nil
        var closes = 0
        focus.release { closes += 1 }
        #expect(!query.isFirstResponder && closes == 0)
        focus.detach(query)
        let replacement = SearchQueryTextField(focus: focus)
        replacement.frame = query.frame
        window.rootViewController?.view.addSubview(replacement)
        #expect(replacement.becomeFirstResponder())
        var replacementCloses = 0
        focus.release { replacementCloses += 1 }
        #expect(replacementCloses == 1 && !replacement.isFirstResponder)
        query.delegate = query
        #expect(query.becomeFirstResponder())
        query.resignFirstResponder()
        #expect(closes == 0 && replacementCloses == 1)
    }

    @Test("a keyboard hide notification cannot revoke a different live native responder")
    func unrelatedKeyboardHidePreservesTheActualEditingOwner() {
        var focusEvents: [Bool] = []
        let (window, host) = installedHost(state: .editing, onFocus: { focusEvents.append($0) })
        defer { host.editor.resignFirstResponder(); window.isHidden = true; window.rootViewController = nil }
        #expect(host.editor.becomeFirstResponder())
        focusEvents.removeAll()
        NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification,
                                        object: window.screen)
        #expect(host.editor.isFirstResponder)
        #expect(focusEvents.isEmpty, "software keyboard visibility is not the actual responder's focus")
    }

    @Test("Search ends its own editing before restore; hosting updates and teardown keep the responder")
    func searchHostingTeardownCannotRevokeTheRetainedComposer() async throws {
        let (window, composer) = installedHost()
        let state = SearchFocusHostingState()
        let focus = SearchQueryFocus()
        let parent = try #require(window.rootViewController)
        let root = UIHostingController(rootView: SearchFocusHostingView(state: state, focus: focus))
        parent.addChild(root)
        root.view.frame = parent.view.bounds
        parent.view.insertSubview(root.view, at: 0)
        root.didMove(toParent: parent)
        root.view.layoutIfNeeded()
        defer { composer.editor.resignFirstResponder(); window.isHidden = true; window.rootViewController = nil }
        let editor = composer.editor
        #expect(editor.becomeFirstResponder())
        let token = try #require(composer.captureOverlayFocus(ownerIsCurrent: { true }))
        composer.setWorkspaceInputSuppressed(true)
        await drain { self.findSearchField(in: root.view) != nil }
        let query = try #require(findSearchField(in: root.view))
        #expect(query.becomeFirstResponder())
        query.text = "native query edit"
        query.sendActions(for: .editingChanged)
        #expect(state.query == "native query edit")
        var releases = 0
        focus.release {
            #expect(!query.isFirstResponder, "native query didEnd must precede restore")
            releases += 1
            composer.setWorkspaceInputSuppressed(false)
            token.restore()
        }
        #expect(releases == 1 && editor.isFirstResponder)
        // Keep the outgoing view mounted for a real representable update, as
        // happens during the overlay fade, then let SwiftUI dismantle it.
        state.query = "query update during the outgoing fade"
        await drain { query.text == state.query }
        #expect(query.text == state.query)
        #expect(editor.isFirstResponder)
        #expect(query.onText != nil)
        state.showsSearch = false
        // SwiftUI may retain an outgoing UIKit view in its Window after
        // dismantle. The production callback is cleared only by dismantle,
        // so it proves the lifecycle event independently of view retirement.
        await drain { root.view.layoutIfNeeded(); return query.onText == nil }
        #expect(query.onText == nil && editor.isFirstResponder)
        #expect(composer.editor === editor && editor.text == "same draft")
        #expect(releases == 1)
    }

    @Test("an unfocused Search closes immediately and only once")
    func unfocusedQueryDoesNotWaitForAnEditingCallback() {
        let focus = SearchQueryFocus()
        let query = SearchQueryTextField(focus: focus)
        var closes = 0
        focus.release { closes += 1 }
        focus.release { closes += 1 }
        focus.detach(query)
        #expect(closes == 1 && !query.isFirstResponder)
    }

    private func findSearchField(in view: UIView) -> SearchQueryTextField? {
        if let query = view as? SearchQueryTextField { return query }
        return view.subviews.lazy.compactMap { findSearchField(in: $0) }.first
    }

    private func drain(until condition: () -> Bool) async {
        for _ in 0..<30 where !condition() {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test(arguments: [true, false])
    func retainedSurfaceMountRestoresAfterItsVisibilityGateOpens(inputBeforeMount: Bool) throws {
        let (window, composer) = installedHost()
        let surface = ConversationSurfaceViewController(content: Text("retained content"))
        window.rootViewController = surface
        surface.view.layoutIfNeeded()
        composer.frame = surface.contentController.view.bounds
        surface.contentController.view.addSubview(composer)
        composer.layoutIfNeeded()
        defer { composer.editor.resignFirstResponder(); window.isHidden = true; window.rootViewController = nil }
        let editor = composer.editor
        #expect(editor.becomeFirstResponder())
        let token = try #require(composer.captureOverlayFocus(ownerIsCurrent: { true }))
        composer.setWorkspaceInputSuppressed(true)
        surface.setWorkspaceVisible(false)
        token.restore()
        if inputBeforeMount {
            // The bridge can reopen input before its retained parent remounts.
            composer.setWorkspaceInputSuppressed(false)
            composer.requestFocus(false)
            composer.consumeOverlayFocusIfReady()
            #expect(!editor.isFirstResponder)
            surface.setWorkspaceVisible(true)
        } else {
            surface.setWorkspaceVisible(true)
            #expect(!editor.isFirstResponder)
            composer.setWorkspaceInputSuppressed(false)
            composer.requestFocus(false)
            composer.consumeOverlayFocusIfReady()
        }
        #expect(editor.isFirstResponder)
        #expect(composer.editor === editor && editor.text == "same draft")
    }

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

    private func installedHost(state: ComposerPresentationState = .resting,
                               onFocus: @escaping (Bool) -> Void = { _ in }) -> (UIWindow, ComposerHostView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIViewController()
        window.rootViewController = root; window.makeKeyAndVisible()
        let host = ComposerHostView(frame: root.view.bounds)
        root.view.addSubview(host)
        host.configure(.init(text: "same draft", selection: .init(range: 0..<0), state: state,
            collapseProgress: .expanded, font: .systemFont(ofSize: 16), showsPlus: false,
            primary: .send(enabled: false), models: [], selectedModelID: nil, errorMessage: nil,
            references: [], onRemoveQuote: { _ in }, onAcceptQuote: { _ in }, onQuotePhase: { _ in },
            onText: { _, _, _ in }, onFocus: onFocus, onSend: {}, onStop: {}, onModel: { _ in },
            onHeightChanged: { _ in }))
        host.layoutIfNeeded()
        return (window, host)
    }
}

@MainActor
@Observable
private final class SearchFocusHostingState {
    var showsSearch = true
    var query = ""
}

@MainActor
private struct SearchFocusHostingView: View {
    @Bindable var state: SearchFocusHostingState
    let focus: SearchQueryFocus

    var body: some View {
        if state.showsSearch {
            SearchQueryInput(text: state.query, font: .systemFont(ofSize: 16), focus: focus,
                             onText: { state.query = $0 })
                .frame(width: 300, height: 44)
        } else {
            Color.clear
        }
    }
}

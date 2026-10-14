import Observation
import SwiftUI
import Testing
import UIKit
@testable import ZenAgent

@Suite("Settings native release acknowledgement")
@MainActor
struct SettingsInputFocusTests {
    @Test("a tracked field cannot authorize Close before its actual end-editing callback")
    func trackedFieldWaitsForAcknowledgement() {
        let focus = SettingsInputFocus()
        let field = UITextField()
        let other = UITextField()
        // Exercise the event ordering where the native flag is already clear,
        // while this presentation has not received its matching delegate event.
        focus.began(field)
        #expect(!field.isFirstResponder)
        var closed = false
        focus.release { closed = true }
        #expect(!closed)
        focus.ended(other)
        #expect(!closed, "A different Settings field cannot acknowledge this release")
        focus.ended(field)
        #expect(closed)
    }

    @Test("cancellation prevents a late end-editing callback from restoring the Conversation")
    func cancelledReleaseCannotPublishALateClose() {
        let focus = SettingsInputFocus()
        let field = UITextField()
        focus.began(field)
        var closed = false
        focus.release { closed = true }
        focus.cancel()
        focus.ended(field)
        #expect(!closed)
    }

    @Test("a presentation without an owned field needs no native release acknowledgement")
    func noOwnedFieldClosesImmediately() {
        let focus = SettingsInputFocus()
        var closed = false
        focus.release { closed = true }
        #expect(closed)
    }
}

@MainActor
@Observable
private final class SettingsNativeInputFixtureState {
    var instructions = "same Soul instructions"
    var busy = false
}

@MainActor
private struct SettingsNativeInputFixture: View {
    @Bindable var state: SettingsNativeInputFixtureState
    let focus: SettingsInputFocus
    let close: () -> Void
    var body: some View {
        NavigationStack {
            Form {
                SettingsInstructionsInput(text: $state.instructions, focus: focus)
                    .frame(minHeight: 180).disabled(state.busy)
            }.settingsCloseToolbar()
        }.environment(\.settingsCloseControl,
                      SettingsCloseControl(focus: focus, blocked: state.busy, close: close))
    }
}

@Suite("Settings real native text input close", .serialized)
@MainActor
struct SettingsNativeInputCloseTests {
    @Test("the actual Instructions representable releases its responder after Save-style updates",
          arguments: [false, true])
    func nativeInstructionsCloseAcknowledgesEditing(saveStyleUpdate: Bool) async throws {
        let state = SettingsNativeInputFixtureState()
        let focus = SettingsInputFocus()
        var closes = 0
        let root = UIHostingController(rootView: SettingsNativeInputFixture(
            state: state, focus: focus, close: { closes += 1 }))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.endEditing(true); window.isHidden = true; window.rootViewController = nil }
        func editor(in view: UIView) -> UITextView? {
            if let text = view as? UITextView, text.accessibilityIdentifier == "settings-soul-instructions" { return text }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        for _ in 0..<30 where editor(in: root.view) == nil {
            root.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        let input = try #require(editor(in: root.view))
        try #require(input.becomeFirstResponder())
        input.selectedRange = NSRange(location: input.text.utf16.count, length: 0)
        input.insertText(" plus edited instructions.")
        let edited = "same Soul instructions plus edited instructions."
        for _ in 0..<30 where state.instructions != edited {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(state.instructions == edited)
        if saveStyleUpdate {
            state.busy = true
            for _ in 0..<5 {
                root.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            state.busy = false
            for _ in 0..<5 {
                root.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(input.becomeFirstResponder())
        }
        #expect(input.delegate != nil && input.isEditable)
        focus.release { closes += 1 }
        for _ in 0..<30 where closes == 0 {
            root.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(closes == 1)
        #expect(!input.isFirstResponder)
        for _ in 0..<30 where input.isUserInteractionEnabled {
            root.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!input.isUserInteractionEnabled, "The closing presentation rejects new input")
        #expect(input.isEditable, "Close must not disable the native editing mode during resignation")
        #expect(state.instructions == edited)
        focus.release { closes += 1 }
        #expect(closes == 1, "Close remains idempotent for the same presentation")
    }
}

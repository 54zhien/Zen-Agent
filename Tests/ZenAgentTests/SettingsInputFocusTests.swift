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

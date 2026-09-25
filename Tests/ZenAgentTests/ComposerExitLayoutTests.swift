import SwiftUI
import Testing
import UIKit

@testable import ZenAgent

@MainActor
@Suite("Composer exit layout")
struct ComposerExitLayoutTests {
    @Test("exit intent keeps the editable layout until the visible transition settles")
    func exitKeepsMultilineUntilSettled() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let view = ComposerTextView(
            text: .constant("first line\nsecond line"),
            selection: .constant(ComposerSelection(range: 0..<0)),
            isFocused: .constant(true),
            isEditing: false,
            typographyRole: .interfaceBody,
            dynamicTypeSize: .medium,
            textAreaIsScrollable: false,
            onCompositionChange: { _ in },
            onKeyboardTransition: { _ in },
            onMeasuredTextHeight: { _ in }
        )
        let controller = UIHostingController(rootView: view)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        let editor = firstTextView(in: controller.view)
        #expect(editor?.textContainer.maximumNumberOfLines == 0)
    }

    private func firstTextView(in view: UIView) -> UITextView? {
        if let editor = view as? UITextView { return editor }
        for child in view.subviews {
            if let editor = firstTextView(in: child) { return editor }
        }
        return nil
    }
}

import Testing
import UIKit
import SwiftUI

@testable import ZenAgent

@MainActor
@Suite("Quote text view native responder preservation", .serialized)
struct QuoteTextViewTests {
    @Test("an untouched read-only quote can acquire, release, and reacquire focus with its selection")
    func untouchedReadOnlyQuotePreservesNativeSelectionAcrossFocusRequests() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let body = "read quote text"
        let root = UIHostingController(rootView: QuoteSelectableText(
            text: body,
            source: QuoteSourceText(
                conversationID: "focus-preservation",
                messageID: "message",
                partID: "body",
                text: body,
                isCompleted: true
            ),
            typographyRole: .conversationBody,
            dynamicTypeSize: .large,
            onSingleTap: {}
        ).frame(width: 340, height: 100))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            window.endEditing(true)
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }

        root.view.frame = window.bounds
        root.view.layoutIfNeeded()
        for _ in 0..<40 where findQuoteTextView(in: root.view) == nil {
            try await Task.sleep(for: .milliseconds(25))
        }
        let quote = try #require(findQuoteTextView(in: root.view))
        try #require(quote.window === window)
        #expect(window.isKeyWindow)
        #expect(!quote.isEditable && quote.isSelectable)

        // No touch is sent: programmatic or assistive focus must still reach UIKit.
        #expect(quote.becomeFirstResponder())
        #expect(quote.isFirstResponder)

        let selection = NSRange(location: 5, length: 5)
        quote.selectedRange = selection
        #expect(quote.selectedRange == selection)
        let selectedTextRange = try #require(quote.selectedTextRange)
        #expect(quote.text(in: selectedTextRange) == "quote")

        #expect(quote.resignFirstResponder())
        #expect(!quote.isFirstResponder)
        #expect(quote.selectedRange == selection, "releasing focus must retain the static selection")

        #expect(quote.becomeFirstResponder(), "a later focus request must be admitted with an existing selection")
        #expect(quote.isFirstResponder)
        #expect(quote.selectedRange == selection)
        let restoredTextRange = try #require(quote.selectedTextRange)
        #expect(quote.text(in: restoredTextRange) == "quote")
        #expect(quote.resignFirstResponder())
        #expect(!quote.isFirstResponder)
    }

    private func findQuoteTextView(in view: UIView) -> QuoteTextView? {
        if let textView = view as? QuoteTextView { return textView }
        for child in view.subviews {
            if let match = findQuoteTextView(in: child) { return match }
        }
        return nil
    }
}

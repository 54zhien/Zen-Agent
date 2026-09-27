import XCTest

final class ConversationReadingPositionUITests: XCTestCase {
    @MainActor
    func testStreamingPreservesOlderTurnUntilNewContentIsTappedAndComposerRemainsInteractive() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_CONVERSATION_READING_UI_TEST"] = "1"
        app.launch()

        let scrollView = app.scrollViews.firstMatch
        XCTAssertTrue(scrollView.waitForExistence(timeout: 15))

        let anchor = app.staticTexts["OLDER_READING_POSITION_ANCHOR_TURN_12"]
        XCTAssertTrue(
            anchor.waitForExistence(timeout: 15),
            "The launch route must display the real Conversation Pane's older Turn."
        )
        XCTAssertTrue(scrollUntilHittable(anchor, in: scrollView))
        let initialAnchorY = anchor.frame.minY

        let injectDelta = app.buttons["conversation-reading-test-inject-delta"]
        XCTAssertTrue(injectDelta.waitForExistence(timeout: 5))
        injectDelta.tap()

        let newContent = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "有新内容")
        ).firstMatch
        XCTAssertTrue(newContent.waitForExistence(timeout: 10))
        XCTAssertTrue(
            waitForFrameY(anchor, toRemainAt: initialAnchorY, tolerance: 10),
            "A live delta in the last Run must not move the older Turn being read."
        )

        newContent.tap()
        let liveDelta = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "CONTROLLED_LIVE_ASSISTANT_DELTA")
        ).firstMatch
        XCTAssertTrue(liveDelta.waitForExistence(timeout: 10))
        XCTAssertTrue(liveDelta.isHittable, "Tapping new content must reveal the newest assistant text.")

        XCTAssertTrue(scrollUntilHittable(anchor, in: scrollView))
        let anchorBeforeKeyboard = anchor.frame.minY
        let input = app.textViews["conversation-composer-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()

        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 8))
        XCTAssertTrue(input.isHittable, "The Composer must remain usable while its keyboard is visible.")
        XCTAssertTrue(
            waitForFrameY(anchor, toRemainAt: anchorBeforeKeyboard, tolerance: 18),
            "Showing the keyboard while reading must retain the visible older Turn."
        )
        input.typeText("KEYBOARD_DRAFT")
        XCTAssertTrue((input.value as? String ?? "").contains("KEYBOARD_DRAFT"))

        keyboard.swipeDown()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 8))
        XCTAssertTrue(anchor.exists, "The older Turn must remain available after the keyboard hides.")
        XCTAssertTrue(input.isHittable, "The Composer must remain available after the keyboard hides.")

        input.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 8))
        keyboard.swipeDown()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 8))
    }

    @MainActor
    private func scrollUntilHittable(_ element: XCUIElement, in scrollView: XCUIElement) -> Bool {
        for _ in 0..<10 {
            if element.exists && element.isHittable { return true }
            scrollView.swipeUp()
        }
        return element.exists && element.isHittable
    }

    @MainActor
    private func waitForFrameY(
        _ element: XCUIElement,
        toRemainAt expectedY: CGFloat,
        tolerance: CGFloat
    ) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if element.exists,
               element.isHittable,
               abs(element.frame.minY - expectedY) <= tolerance {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return element.exists
            && element.isHittable
            && abs(element.frame.minY - expectedY) <= tolerance
    }
}

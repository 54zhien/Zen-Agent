import XCTest

final class ConversationReadingPositionUITests: XCTestCase {
    @MainActor
    func testStreamingPreservesOlderTurnUntilNewContentIsTappedAndComposerRemainsInteractive() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_CONVERSATION_READING_UI_TEST"] = "1"
        app.launch()

        let scrollView = app.scrollViews.firstMatch
        XCTAssertTrue(scrollView.waitForExistence(timeout: 15))

        let anchor = app.staticTexts["OLDER_READING_POSITION_ANCHOR_TURN_10"]
        let previousTurnResponse = app.staticTexts["Assistant response for Turn 9"]
        let currentTurnPrompt = app.staticTexts["User prompt for Turn 10"]
        XCTAssertTrue(scrollUntilTurnIsReadable(
            anchor,
            previousTurnResponse: previousTurnResponse,
            currentTurnPrompt: currentTurnPrompt,
            direction: .older,
            in: scrollView
        ), "The real Pane must let the test scroll to an older visible Turn.")
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

        XCTAssertTrue(scrollUntilTurnIsReadable(
            anchor,
            previousTurnResponse: previousTurnResponse,
            currentTurnPrompt: currentTurnPrompt,
            direction: .older,
            in: scrollView
        ))
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

        tapBlankTurnGap(
            after: previousTurnResponse,
            before: currentTurnPrompt,
            in: scrollView
        )
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 8))
        XCTAssertTrue(anchor.exists, "The older Turn must remain available after the keyboard hides.")
        XCTAssertTrue(input.isHittable, "The Composer must remain available after the keyboard hides.")

        input.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 8))
        tapBlankTurnGap(
            after: previousTurnResponse,
            before: currentTurnPrompt,
            in: scrollView
        )
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 8))
    }

    @MainActor
    private func scrollUntilTurnIsReadable(
        _ anchor: XCUIElement,
        previousTurnResponse: XCUIElement,
        currentTurnPrompt: XCUIElement,
        direction: TimelineScrollDirection,
        in scrollView: XCUIElement
    ) -> Bool {
        for _ in 0..<10 {
            if anchor.exists,
               anchor.isHittable,
               previousTurnResponse.exists,
               previousTurnResponse.isHittable,
               currentTurnPrompt.exists,
               currentTurnPrompt.isHittable {
                return true
            }
            switch direction {
            case .older:
                scrollView.swipeDown()
            case .newer:
                scrollView.swipeUp()
            }
        }
        return anchor.exists
            && anchor.isHittable
            && previousTurnResponse.exists
            && previousTurnResponse.isHittable
            && currentTurnPrompt.exists
            && currentTurnPrompt.isHittable
    }

    @MainActor
    private func tapBlankTurnGap(
        after olderResponse: XCUIElement,
        before newerPrompt: XCUIElement,
        in scrollView: XCUIElement
    ) {
        XCTAssertTrue(olderResponse.isHittable)
        XCTAssertTrue(newerPrompt.isHittable)
        let gapStart = olderResponse.frame.maxY
        let gapEnd = newerPrompt.frame.minY
        XCTAssertGreaterThan(gapEnd - gapStart, 8, "The fixture must leave a blank gap between Turns.")

        let normalizedY = ((gapStart + gapEnd) / 2 - scrollView.frame.minY) / scrollView.frame.height
        XCTAssertGreaterThan(normalizedY, 0)
        XCTAssertLessThan(normalizedY, 1)
        scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: normalizedY)).tap()
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

    private enum TimelineScrollDirection {
        case older
        case newer
    }
}

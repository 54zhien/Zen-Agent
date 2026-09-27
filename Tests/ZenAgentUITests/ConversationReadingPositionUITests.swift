import XCTest

final class ConversationReadingPositionUITests: XCTestCase {
    @MainActor
    func testStreamingPreservesOlderTurnUntilNewContentIsTappedAndComposerRemainsInteractive() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_CONVERSATION_READING_UI_TEST"] = "1"
        app.launch()

        let paneScrollViews = app.scrollViews.matching(
            identifier: "conversation-pane-conversation-reading-ui-test-conversation"
        )
        XCTAssertEqual(paneScrollViews.count, 1, "Expected one scroll view inside the real Conversation Pane.")
        let scrollView = paneScrollViews.firstMatch
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

        let dragStart = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62))
        let dragEnd = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.54))
        dragStart.press(forDuration: 0.1, thenDragTo: dragEnd)
        XCTAssertTrue(anchor.isHittable, "The older reading Turn must stay visible after positioning its blank gap.")
        XCTAssertTrue(previousTurnResponse.isHittable)
        XCTAssertTrue(currentTurnPrompt.isHittable)
        let keyboardAnchorY = anchor.frame.minY
        XCTAssertGreaterThan(keyboardAnchorY, 150)
        XCTAssertLessThan(keyboardAnchorY, 350, "Position the reading Turn above the expanded Composer.")

        let input = app.textViews["conversation-composer-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let readingMode = app.buttons["conversation-reading-test-inject-delta"]
        input.tap()

        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 8))
        XCTAssertTrue(input.isHittable, "The Composer must remain usable while its keyboard is visible.")
        XCTAssertTrue(
            waitForFrameY(anchor, toRemainAt: keyboardAnchorY, tolerance: 18),
            "Showing the keyboard must preserve the visible reading Turn position; timeline=\(scrollView.frame), anchor=\(anchor.frame)."
        )
        XCTAssertFalse(liveDelta.isHittable, "Keyboard focus must not silently move reading to the newest content.")
        XCTAssertTrue(
            (readingMode.value as? String ?? "").contains("reading"),
            "Keyboard focus must preserve the Pane's older-Turn reading mode."
        )
        input.typeText("KEYBOARD_DRAFT")
        XCTAssertTrue((input.value as? String ?? "").contains("KEYBOARD_DRAFT"))

        let anchorYBeforeKeyboardDismissal = anchor.frame.minY
        tapBlankTurnGap(
            in: app,
            after: previousTurnResponse,
            before: currentTurnPrompt,
            composerInput: input,
            keyboard: keyboard
        )
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 8))
        XCTAssertTrue(
            waitForFrameY(anchor, toRemainAt: anchorYBeforeKeyboardDismissal, tolerance: 18),
            "Hiding the keyboard must preserve the visible reading Turn position."
        )
        XCTAssertTrue(input.isHittable, "The Composer must remain available after the keyboard hides.")

        let anchorYBeforeSecondPresentation = anchor.frame.minY
        input.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 8))
        XCTAssertTrue(
            waitForFrameY(anchor, toRemainAt: anchorYBeforeSecondPresentation, tolerance: 18),
            "A second keyboard presentation must preserve the visible reading Turn position."
        )
        let anchorYBeforeSecondDismissal = anchor.frame.minY
        tapBlankTurnGap(
            in: app,
            after: previousTurnResponse,
            before: currentTurnPrompt,
            composerInput: input,
            keyboard: keyboard
        )
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 8))
        XCTAssertTrue(
            waitForFrameY(anchor, toRemainAt: anchorYBeforeSecondDismissal, tolerance: 18),
            "A second keyboard dismissal must preserve the visible reading Turn position."
        )
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
        in app: XCUIApplication,
        after olderResponse: XCUIElement,
        before newerPrompt: XCUIElement,
        composerInput: XCUIElement,
        keyboard: XCUIElement? = nil
    ) {
        XCTAssertTrue(olderResponse.isHittable)
        XCTAssertTrue(newerPrompt.isHittable)
        let gapStart = olderResponse.frame.maxY
        let gapEnd = newerPrompt.frame.minY
        XCTAssertGreaterThan(gapEnd - gapStart, 8, "The fixture must leave a blank gap between Turns.")
        // The prompt label sits inside its capsule's 12pt vertical padding. Tap the
        // between-Turn whitespace after the previous response, before that capsule begins.
        let tapY = gapStart + 8
        XCTAssertLessThan(tapY, gapEnd - 16, "The tap must stay outside the next Turn's capsule padding.")
        XCTAssertLessThan(
            tapY,
            composerInput.frame.minY - 16,
            "The blank tap must stay above the Composer surface with room to spare."
        )
        if let keyboard, keyboard.exists {
            XCTAssertLessThan(tapY, keyboard.frame.minY, "The visible Turn gap must remain above the keyboard.")
        }

        let normalizedY = (tapY - app.frame.minY) / app.frame.height
        XCTAssertGreaterThan(normalizedY, 0)
        XCTAssertLessThan(normalizedY, 1)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: normalizedY)).tap()
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

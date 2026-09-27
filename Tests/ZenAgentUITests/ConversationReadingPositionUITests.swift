import XCTest

final class ConversationReadingPositionUITests: XCTestCase {
    @MainActor
    func testStreamingPreservesOlderTurnUntilNewContentIsTappedAndComposerRemainsInteractive() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_CONVERSATION_READING_UI_TEST"] = "1"
        app.launch()

        let scrollView = app.scrollViews[
            "conversation-timeline-scroll-conversation-reading-ui-test-conversation"
        ]
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
        let input = app.textViews["conversation-composer-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let readingMode = app.buttons["conversation-reading-test-inject-delta"]
        logGeometry(
            "before-keyboard",
            timeline: scrollView,
            anchor: anchor,
            keyboard: app.keyboards.firstMatch,
            readingMode: readingMode
        )
        input.tap()

        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 8))
        logGeometry(
            "keyboard-shown",
            timeline: scrollView,
            anchor: anchor,
            keyboard: keyboard,
            readingMode: readingMode
        )
        attachFocusedState(app)
        XCTAssertTrue(input.isHittable, "The Composer must remain usable while its keyboard is visible.")
        XCTAssertTrue(
            anchor.isHittable,
            "Showing the keyboard must keep the older reading Turn visible; timeline=\(scrollView.frame), anchor=\(anchor.frame)."
        )
        XCTAssertFalse(liveDelta.isHittable, "Keyboard focus must not silently move reading to the newest content.")
        XCTAssertTrue(
            (readingMode.value as? String ?? "").contains("reading"),
            "Keyboard focus must preserve the Pane's older-Turn reading mode."
        )
        input.typeText("KEYBOARD_DRAFT")
        XCTAssertTrue((input.value as? String ?? "").contains("KEYBOARD_DRAFT"))

        XCTAssertTrue(scrollUntilTurnIsReadable(
            anchor,
            previousTurnResponse: previousTurnResponse,
            currentTurnPrompt: currentTurnPrompt,
            direction: .older,
            in: scrollView
        ), "Re-find the visible Turn gap after keyboard reflow before dismissing by blank tap.")
        tapBlankTurnGap(
            after: previousTurnResponse,
            before: currentTurnPrompt,
            in: scrollView
        )
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 8))
        XCTAssertTrue(anchor.isHittable, "The older Turn must remain visible after the keyboard hides.")
        XCTAssertTrue(input.isHittable, "The Composer must remain available after the keyboard hides.")

        input.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 8))
        XCTAssertTrue(scrollUntilTurnIsReadable(
            anchor,
            previousTurnResponse: previousTurnResponse,
            currentTurnPrompt: currentTurnPrompt,
            direction: .older,
            in: scrollView
        ), "Re-find the blank gap on the second keyboard presentation.")
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
    private func logGeometry(
        _ phase: String,
        timeline: XCUIElement,
        anchor: XCUIElement,
        keyboard: XCUIElement,
        readingMode: XCUIElement
    ) {
        let keyboardFrame = keyboard.exists ? String(describing: keyboard.frame) : "hidden"
        let anchorFrame = anchor.exists ? String(describing: anchor.frame) : "missing"
        let mode = readingMode.value as? String ?? "unavailable"
        print(
            "READING_UI_GEOMETRY phase=\(phase) timeline=\(timeline.frame) "
                + "anchor=\(anchorFrame) keyboard=\(keyboardFrame) mode=\(mode)"
        )
    }

    @MainActor
    private func attachFocusedState(_ app: XCUIApplication) {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Conversation reading accessibility hierarchy with keyboard"

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Conversation reading screen with keyboard"
        XCTContext.runActivity(named: "Conversation reading geometry with keyboard") { activity in
            activity.add(hierarchy)
            activity.add(screenshot)
        }
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

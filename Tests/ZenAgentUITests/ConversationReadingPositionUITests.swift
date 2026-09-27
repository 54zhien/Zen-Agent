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
        let nextTurnPrompt = app.staticTexts["User prompt for Turn 11"]
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
        let keyboardAnchorY = positionAnchorForKeyboard(
            anchor,
            followingTurnPrompt: nextTurnPrompt,
            composerInput: input,
            in: scrollView
        )
        XCTAssertTrue(anchor.isHittable, "The older reading Turn must stay visible after positioning its blank gap.")
        XCTAssertTrue(nextTurnPrompt.isHittable, "The following Turn must be visible to locate the blank gap below the anchor.")
        XCTAssertGreaterThan(keyboardAnchorY, 150)
        XCTAssertLessThan(keyboardAnchorY, 350, "Position the reading Turn above the expanded Composer.")

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
        let observedInputValue = input.value as? String ?? String(describing: input.value)
        XCTAssertTrue(
            observedInputValue.contains("KEYBOARD_DRAFT"),
            "Expected keyboard text entry. value=\(observedInputValue), "
                + "keyboardExists=\(keyboard.exists), keyboardHittable=\(keyboard.isHittable), "
                + "keyboardFrame=\(keyboard.frame), inputFrame=\(input.frame)."
        )

        let anchorYBeforeKeyboardDismissal = anchor.frame.minY
        tapBlankTurnGap(
            in: app,
            after: anchor,
            before: nextTurnPrompt,
            composerInput: input,
            keyboard: keyboard
        )
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 8))
        logGeometry(
            "keyboard-hidden",
            timeline: scrollView,
            anchor: anchor,
            keyboard: keyboard,
            readingMode: readingMode
        )
        XCTAssertTrue(
            waitForFrameY(anchor, toRemainAt: anchorYBeforeKeyboardDismissal, tolerance: 18),
            "Hiding the keyboard must preserve the visible reading Turn position."
        )
        XCTAssertTrue(input.isHittable, "The Composer must remain available after the keyboard hides.")

        let anchorYBeforeSecondPresentation = anchor.frame.minY
        input.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 8))
        logGeometry(
            "keyboard-shown-again",
            timeline: scrollView,
            anchor: anchor,
            keyboard: keyboard,
            readingMode: readingMode
        )
        XCTAssertTrue(
            waitForFrameY(anchor, toRemainAt: anchorYBeforeSecondPresentation, tolerance: 18),
            "A second keyboard presentation must preserve the visible reading Turn position."
        )
        let anchorYBeforeSecondDismissal = anchor.frame.minY
        tapBlankTurnGap(
            in: app,
            after: anchor,
            before: nextTurnPrompt,
            composerInput: input,
            keyboard: keyboard
        )
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 8))
        logGeometry(
            "keyboard-hidden-again",
            timeline: scrollView,
            anchor: anchor,
            keyboard: keyboard,
            readingMode: readingMode
        )
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
    private func positionAnchorForKeyboard(
        _ anchor: XCUIElement,
        followingTurnPrompt: XCUIElement,
        composerInput: XCUIElement,
        in scrollView: XCUIElement
    ) -> CGFloat {
        let initialTimelineFrame = scrollView.frame
        let timelineHeight = initialTimelineFrame.height
        guard timelineHeight > 0 else {
            XCTFail("Cannot position the anchor in an empty timeline frame: \(initialTimelineFrame).")
            return anchor.frame.minY
        }

        let lowerBound: CGFloat = 150
        let upperBound: CGFloat = 350
        let maximumDragFraction: CGFloat = 0.08
        var dragFraction = maximumDragFraction
        var observedPositions: [CGFloat] = []

        for _ in 0..<6 {
            let anchorFrame = anchor.frame
            let promptFrame = followingTurnPrompt.frame
            let currentY = anchorFrame.minY
            let tapY = anchorFrame.maxY + 8
            observedPositions.append(currentY)

            guard upperBound > lowerBound else {
                break
            }

            let gapIsSafe = tapY < promptFrame.minY - 16
            let composerIsClear = tapY < composerInput.frame.minY - 16
            let turnIsReadable = anchor.exists
                && anchor.isHittable
                && followingTurnPrompt.exists
                && followingTurnPrompt.isHittable
            if currentY > lowerBound,
               currentY < upperBound,
               gapIsSafe,
               composerIsClear,
               turnIsReadable {
                return currentY
            }

            // Scrolling cannot change the distance between two fixture Turns.
            if anchor.exists, followingTurnPrompt.exists, !gapIsSafe {
                break
            }

            let moveContentUp: Bool
            if currentY <= lowerBound {
                moveContentUp = false
            } else if currentY >= upperBound
                        || !followingTurnPrompt.isHittable
                        || !composerIsClear {
                moveContentUp = true
            } else if !anchor.isHittable {
                moveContentUp = false
            } else {
                break
            }

            let distanceToSafeRange = moveContentUp
                ? max(0, currentY - upperBound)
                : max(0, lowerBound - currentY)
            let requestedFraction = min(
                maximumDragFraction,
                min(dragFraction, max(0.01, distanceToSafeRange / timelineHeight))
            )
            let dragStartY: CGFloat = moveContentUp ? 0.62 : 0.54
            let dragEndY = dragStartY + (moveContentUp ? -requestedFraction : requestedFraction)
            let dragStart = scrollView.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: dragStartY)
            )
            let dragEnd = scrollView.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: dragEndY)
            )
            dragStart.press(forDuration: 0.1, thenDragTo: dragEnd, withVelocity: .slow, thenHoldForDuration: 0.2)

            let updatedY = anchor.frame.minY
            observedPositions.append(updatedY)
            let crossedSafeRange = (currentY >= upperBound && updatedY <= lowerBound)
                || (currentY <= lowerBound && updatedY >= upperBound)
            if crossedSafeRange {
                dragFraction = max(0.005, requestedFraction / 2)
            } else if abs(updatedY - currentY) < 2 {
                dragFraction = min(maximumDragFraction, requestedFraction * 1.5)
            } else {
                dragFraction = requestedFraction
            }
        }

        let finalFrame = anchor.frame
        let finalTapY = finalFrame.maxY + 8
        let finalPromptFrame = followingTurnPrompt.frame
        let isSafe = finalFrame.minY > lowerBound
            && finalFrame.minY < upperBound
            && finalTapY < finalPromptFrame.minY - 16
            && finalTapY < composerInput.frame.minY - 16
            && anchor.isHittable
            && followingTurnPrompt.isHittable
        XCTAssertTrue(
            isSafe,
            "Could not place the reading Turn at a blank-tap-safe position. "
                + "safeY=\(lowerBound)...\(upperBound), "
                + "tapY=\(finalTapY), restingComposerTop=\(composerInput.frame.minY), "
                + "observedY=\(observedPositions), anchor=\(finalFrame), "
                + "followingPrompt=\(finalPromptFrame), Composer=\(composerInput.frame), "
                + "timeline=\(scrollView.frame)."
        )
        return finalFrame.minY
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
        print(
            "READING_UI_BLANK_TAP older=\(olderResponse.frame) newer=\(newerPrompt.frame) "
                + "tapY=\(tapY) input=\(composerInput.frame) keyboard=\(keyboard?.frame ?? .zero)"
        )
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: normalizedY)).tap()
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

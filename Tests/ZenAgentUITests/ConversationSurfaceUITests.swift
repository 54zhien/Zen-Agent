import XCTest

final class ConversationSurfaceUITests: XCTestCase {
    @MainActor
    func testTransformedReadingRetainsOlderTurnThroughLiveDeltaAndReturn() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_SURFACE_UI_TEST"] = "1"
        app.launchEnvironment["ZEN_SURFACE_READING_UI_TEST"] = "1"
        app.launch()
        let position = app.buttons["conversation-reading-test-position-older-turn"]
        XCTAssertTrue(position.waitForExistence(timeout: 15))
        position.tap()
        let anchor = app.staticTexts["OLDER_READING_POSITION_ANCHOR_TURN_10"]
        XCTAssertTrue(anchor.waitForExistence(timeout: 8))
        XCTAssertTrue(waitForPredicate("value BEGINSWITH 'settled-'", on: position))
        let timeline = app.scrollViews["conversation-pane-conversation-reading-ui-test-conversation"]
        let mode = app.buttons["conversation-reading-test-inject-delta"]
        XCTAssertTrue(waitForPredicate("value CONTAINS 'reading'", on: mode))
        let input = app.textViews["conversation-composer-input"]
        let originalTimeline = timeline.frame
        let originalAnchor = anchor.frame
        let originalInput = input.value as? String
        let step = app.buttons["surface-test-step"]
        for progress in ["0.5", "1.0", "0.5", "0.0"] {
            step.tap()
            XCTAssertTrue(waitForValue(progress, on: step))
            XCTAssertTrue(anchor.isHittable)
            // Undo the known affine transform using the real scroll viewport.
            // This detects inner reflow/scroll changes even when the host bounds stay fixed.
            let scale = timeline.frame.width / originalTimeline.width
            let logicalY = (anchor.frame.minY - timeline.frame.minY) / scale
            XCTAssertEqual(logicalY, originalAnchor.minY - originalTimeline.minY, accuracy: 3)
            XCTAssertEqual(anchor.frame.height / scale, originalAnchor.height, accuracy: 3)
            XCTAssertTrue((mode.value as? String ?? "").contains("reading"))
            XCTAssertEqual(input.value as? String, originalInput)
            if progress == "1.0" {
                let beforeDelta = anchor.frame.minY
                mode.tap()
                let newContent = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "有新内容")).firstMatch
                XCTAssertTrue(newContent.waitForExistence(timeout: 8))
                XCTAssertEqual(anchor.frame.minY, beforeDelta, accuracy: 3)
            }
        }
        XCTAssertEqual(anchor.frame.minY, originalAnchor.minY, accuracy: 3)
        let newContent = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "有新内容")).firstMatch
        newContent.tap()
        let delta = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "CONTROLLED_LIVE_ASSISTANT_DELTA")).firstMatch
        XCTAssertTrue(delta.waitForExistence(timeout: 8))
        XCTAssertTrue(delta.isHittable)
    }

    @MainActor
    func testProgressRoundTripPreservesDraftAndMovesNavigationWithComposer() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_SURFACE_UI_TEST"] = "1"
        app.launch()
        let input = app.textViews["conversation-composer-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        input.typeText("SURFACE_DRAFT")
        let originalInputWidth = input.frame.width
        let title = app.navigationBars.firstMatch
        let originalNavigationWidth = title.frame.width
        let step = app.buttons["surface-test-step"]
        XCTAssertTrue(step.waitForExistence(timeout: 5))
        step.tap()
        XCTAssertTrue(waitForValue("0.5", on: step))
        XCTAssertLessThan(input.frame.width, originalInputWidth * 0.9)
        XCTAssertLessThan(title.frame.width, originalNavigationWidth * 0.9)
        step.tap()
        XCTAssertTrue(waitForValue("1.0", on: step))
        step.tap()
        XCTAssertTrue(waitForValue("0.5", on: step))
        step.tap()
        XCTAssertTrue(waitForValue("0.0", on: step))
        XCTAssertEqual(input.frame.width, originalInputWidth, accuracy: 1)
        XCTAssertEqual(title.frame.width, originalNavigationWidth, accuracy: 1)
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 1)
        XCTAssertTrue((input.value as? String ?? "").contains("SURFACE_DRAFT"))
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        input.typeText("_RETURNED")
        XCTAssertTrue((input.value as? String ?? "").contains("SURFACE_DRAFT_RETURNED"))
    }

    @MainActor
    func testReadyShellConfigurationSheetReturnsToSameDraft() {
        let app = XCUIApplication()
        app.launch()
        let input = app.textViews["conversation-composer-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        XCTAssertEqual(app.navigationBars.count, 1)
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        input.typeText("SHEET_DRAFT")
        let configure = app.buttons["new-conversation-configure"]
        XCTAssertTrue(configure.waitForExistence(timeout: 5))
        app.openWorkspaceSidebar()
        XCTAssertTrue(configure.waitForExistence(timeout: 10))
        configure.tap()
        let close = app.buttons["关闭"]
        XCTAssertTrue(close.waitForExistence(timeout: 8))
        close.tap()
        XCTAssertTrue(configure.waitForExistence(timeout: 8))
        XCTAssertTrue((input.value as? String ?? "").contains("SHEET_DRAFT"))
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 1)
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        input.typeText("_RETURNED")
        XCTAssertTrue((input.value as? String ?? "").contains("SHEET_DRAFT_RETURNED"),
                      "Actual draft after sheet Return: \(String(describing: input.value))")
    }

    @MainActor
    private func waitForValue(_ expected: String, on element: XCUIElement) -> Bool {
        let predicate = NSPredicate(format: "value == %@", expected)
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 5) == .completed
    }

    @MainActor
    private func waitForPredicate(_ format: String, on element: XCUIElement) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)], timeout: 8) == .completed
    }
}

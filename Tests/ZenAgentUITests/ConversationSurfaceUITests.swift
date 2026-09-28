import XCTest

final class ConversationSurfaceUITests: XCTestCase {
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
        XCTAssertTrue((input.value as? String ?? "").contains("SHEET_DRAFT_RETURNED"))
    }

    @MainActor
    private func waitForValue(_ expected: String, on element: XCUIElement) -> Bool {
        let predicate = NSPredicate(format: "value == %@", expected)
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 5) == .completed
    }
}

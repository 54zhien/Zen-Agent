import XCTest

final class SplitContainerUITests: XCTestCase {
    @MainActor
    func testPickerSelectionMountsASecondLiveConversation() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launch()
        let editor = app.textViews["conversation-composer-input"]
        guard editor.waitForExistence(timeout: 15) else {
            XCTFail("Seeded Conversation editor missing")
            return
        }
        let start = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.7,
                    thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.18)))
        let picker = app.otherElements["split-empty-pane-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        let history = app.buttons["split-history-preview-ui-10"]
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        history.tap()
        XCTAssertTrue(app.descendants(matching: .any)["conversation-pane-preview-ui-10"]
            .waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["conversation-pane-preview-ui-11"].exists)
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 2)
    }

    @MainActor
    func testAccessibleTopSplitEntryOpensTheSameEmptyPanePicker() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launch()
        XCTAssertTrue(app.textViews["conversation-composer-input"].waitForExistence(timeout: 15))
        let action = app.buttons["split-open-top"]
        XCTAssertTrue(action.waitForExistence(timeout: 10))
        action.tap()
        XCTAssertTrue(app.otherElements["split-empty-pane-picker"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testTopDropKeepsTheSourceAndOpensAnEmptySecondPane() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launch()

        let editor = app.textViews["conversation-composer-input"]
        guard editor.waitForExistence(timeout: 15) else {
            XCTFail("Seeded Conversation editor missing")
            return
        }
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        editor.typeText("Split source draft")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.25)).tap()
        let keyboardHidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !app.keyboards.firstMatch.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardHidden], timeout: 10), .completed)

        let start = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.7,
                    thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.18)))

        XCTAssertTrue(app.otherElements["split-empty-pane-picker"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 1)
        XCTAssertTrue((editor.value as? String)?.contains("Split source draft") == true)
    }
}

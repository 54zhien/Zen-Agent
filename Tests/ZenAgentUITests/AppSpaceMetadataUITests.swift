import XCTest

final class AppSpaceMetadataUITests: XCTestCase {
    @MainActor
    func testRightmostNewCreatesEmptyHistoryWithoutKeyboard() {
        let app = launchInCards()
        let card = app.descendants(matching: .any)["workspace-current-card"]
        card.swipeLeft()
        guard wait({ card.exists && card.label.contains("新对话") }) else {
            XCTFail("The newest persisted card must have a distinct rightmost New entry")
            return
        }
        XCTAssertFalse(app.buttons["workspace-card-menu"].exists)
        card.tap()
        XCTAssertTrue(wait { (app.otherElements["surface-lift-state-probe"].value as? String) == "full" })
        let editor = app.textViews["conversation-composer-input"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(app.keyboards.count, 0)
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 1)
        let point = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        point.press(forDuration: 0.7, thenDragTo: point.withOffset(CGVector(dx: 0, dy: -220)))
        XCTAssertTrue(wait { card.exists })
        XCTAssertTrue(app.buttons["workspace-card-menu"].waitForExistence(timeout: 5))
        card.swipeLeft()
        XCTAssertTrue(wait { card.label.contains("新对话") })
    }

    @MainActor
    func testSelectedCardMenuRenamesAndPinsWithoutOpeningFull() {
        let app = launchInCards()
        let card = app.descendants(matching: .any)["workspace-current-card"]
        let menu = app.buttons["workspace-card-menu"]
        guard menu.waitForExistence(timeout: 5) else {
            XCTFail("Current persisted Card must expose its metadata ellipsis")
            return
        }
        menu.tap()
        app.buttons["重命名"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(" cancelled edit")
        app.alerts.buttons["取消"].tap()
        XCTAssertTrue(wait { card.label.contains("Workspace conversation 11") && !card.label.contains("cancelled edit") })
        menu.tap()
        app.buttons["重命名"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(" Manual title")
        app.alerts.buttons["保存"].tap()
        XCTAssertTrue(wait { card.exists && card.label.contains("Manual title") })
        menu.tap()
        app.buttons["置顶"].tap()
        XCTAssertTrue(wait { card.exists && card.label.contains("Manual title") })
        menu.tap()
        XCTAssertTrue(app.buttons["取消置顶"].waitForExistence(timeout: 5))
        app.buttons["取消置顶"].tap()
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 0)
        card.swipeRight()
        XCTAssertTrue(wait { card.label.contains("Workspace conversation 10") })
    }

    @MainActor
    private func launchInCards() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launch()
        let editor = app.textViews["conversation-composer-input"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        let point = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        point.press(forDuration: 0.7, thenDragTo: point.withOffset(CGVector(dx: 0, dy: -220)))
        XCTAssertTrue(wait { app.descendants(matching: .any)["workspace-current-card"].exists })
        return app
    }

    @MainActor
    private func wait(_ condition: @escaping () -> Bool) -> Bool {
        let pending = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [pending], timeout: 10) == .completed
    }
}

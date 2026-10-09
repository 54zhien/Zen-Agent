import XCTest

final class AppSpaceDeletionUITests: XCTestCase {
    @MainActor
    func testUpwardCurrentDeleteAndUndoKeepTheOriginalConversation() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launch()
        let editor = app.textViews["conversation-composer-input"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        let point = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        point.press(forDuration: 0.7, thenDragTo: point.withOffset(CGVector(dx: 0, dy: -220)))
        let card = app.descendants(matching: .any)["workspace-current-card"]
        XCTAssertTrue(wait { card.exists && card.label.contains("Workspace conversation 11") })

        card.swipeUp()
        let undo = app.buttons["workspace-card-undo-preview-ui-11"]
        XCTAssertTrue(undo.waitForExistence(timeout: 3))
        XCTAssertTrue(card.label.contains("Workspace conversation 10"))
        undo.tap()
        XCTAssertTrue(wait { card.label.contains("Workspace conversation 11") })
        XCTAssertFalse(undo.exists)
    }

    @MainActor
    private func wait(_ condition: @escaping () -> Bool) -> Bool {
        let pending = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [pending], timeout: 10) == .completed
    }
}

import XCTest

final class AppSpaceBrowseUITests: XCTestCase {
    @MainActor
    func testNativeBrowseSnapsOneNeighborAndOpensSelectedHistory() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launch()
        let editor = app.textViews["conversation-composer-input"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        let start = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.7, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -220)))
        let card = app.descendants(matching: .any)["workspace-current-card"]
        XCTAssertTrue(wait { card.exists && card.label.contains("Workspace conversation 11") })
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 0)

        card.swipeRight()
        // This is the existing native Surface. A horizontal drag must browse,
        // not activate its Return tap handler or remount a hidden editor.
        guard wait({ card.exists && card.label.contains("Workspace conversation 10") }) else {
            XCTFail("Horizontal browse did not keep Preview and select the adjacent older history")
            return
        }
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 0)
        card.swipeLeft()
        XCTAssertTrue(wait { card.exists && card.label.contains("Workspace conversation 11") })
        card.swipeRight(velocity: .fast)
        XCTAssertTrue(wait { card.exists && card.label.contains("Workspace conversation 10") })
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 0)
        card.tap()
        XCTAssertTrue(wait { (app.otherElements["surface-lift-state-probe"].value as? String) == "full" })
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 1)
        XCTAssertTrue(app.descendants(matching: .any)["conversation-pane-preview-ui-10"].exists)
    }

    @MainActor
    private func wait(_ condition: @escaping () -> Bool) -> Bool {
        let pending = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [pending], timeout: 10) == .completed
    }
}

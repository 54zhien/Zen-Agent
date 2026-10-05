import XCTest

final class AppSpaceGeometryUITests: XCTestCase {
    @MainActor
    func testStaticCurrentAndHistoryShareHorizontalDepthCenterline() {
        let app = launch()
        let current = app.otherElements["app-space-card-current"]
        guard current.waitForExistence(timeout: 15) else {
            XCTFail("The DEBUG geometry route must display the actual resolver's Current card.")
            return
        }
        XCTAssertGreaterThan(current.frame.midX, app.frame.midX)
        var previousWidth = current.frame.width
        for depth in 1...3 {
            let previous = app.otherElements["app-space-card-history-\(depth)"]
            XCTAssertTrue(previous.exists)
            XCTAssertLessThan(previous.frame.minX, current.frame.minX)
            XCTAssertEqual(previous.frame.midY, current.frame.midY, accuracy: 1)
            XCTAssertLessThan(previous.frame.width, previousWidth)
            XCTAssertTrue(app.frame.insetBy(dx: -1, dy: -1).contains(previous.frame))
            previousWidth = previous.frame.width
        }
        XCTAssertTrue(app.frame.contains(current.frame))
        XCTAssertEqual(app.textViews.count, 0, "Static previews must not instantiate editable Conversation content.")
    }

    @MainActor
    func testNewCanOccupyCurrentWithoutCreatingComposer() {
        let app = launch(new: true)
        let current = app.otherElements["app-space-card-current"]
        guard current.waitForExistence(timeout: 15) else {
            XCTFail("The logical rightmost New sentinel must be renderable as Current.")
            return
        }
        XCTAssertEqual(current.label, "新对话")
        XCTAssertTrue(app.otherElements["app-space-card-history-1"].exists)
        XCTAssertEqual(app.textViews.count, 0)
        XCTAssertEqual(app.otherElements.matching(identifier: "app-space-card-current").count, 1)
    }

    @MainActor
    func testAccessibilityTypeKeepsWholeCardStackInsideViewport() {
        let app = launch(largeType: true)
        let current = app.otherElements["app-space-card-current"]
        guard current.waitForExistence(timeout: 15) else {
            XCTFail("Accessibility text sizes must use the same static geometry fixture.")
            return
        }
        for identifier in ["app-space-card-current", "app-space-card-history-1", "app-space-card-history-2", "app-space-card-history-3"] {
            let card = app.otherElements[identifier]
            XCTAssertTrue(card.exists)
            XCTAssertGreaterThan(card.frame.width, 0)
            XCTAssertGreaterThan(card.frame.height, 0)
            XCTAssertTrue(app.frame.insetBy(dx: -1, dy: -1).contains(card.frame))
        }
        XCTAssertEqual(app.textViews.count, 0)
    }

    @MainActor
    private func launch(new: Bool = false, largeType: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_APP_SPACE_GEOMETRY_UI_TEST"] = "1"
        if new { app.launchEnvironment["ZEN_APP_SPACE_GEOMETRY_NEW"] = "1" }
        if largeType { app.launchEnvironment["ZEN_APP_SPACE_GEOMETRY_AX"] = "1" }
        app.launch()
        return app
    }
}

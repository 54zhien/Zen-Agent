import XCTest

final class SurfaceLiftUITests: XCTestCase {
    @MainActor
    func testLongPressAloneStaysFullAndKeepsDraft() {
        let app = launch()
        guard waitForPhase("full", app: app) else { return }
        guard prepareDraft("Lift 草稿", app: app) else { return }
        let editor = app.textViews["conversation-composer-input"]
        editor.press(forDuration: 0.7)
        XCTAssertTrue(waitForPhase("full", app: app))
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 1)
        XCTAssertTrue((editor.value as? String)?.contains("Lift 草稿") == true)
        XCTAssertFalse(app.descendants(matching: .any)["workspace-current-card"].exists)
    }

    @MainActor
    func testRealDragAndReturnKeepDraftAndReadingPosition() {
        let app = launch()
        guard waitForPhase("full", app: app) else { return }
        let position = app.buttons["conversation-reading-test-position-older-turn"]
        guard position.waitForExistence(timeout: 10) else { XCTFail("Real reading fixture missing"); return }
        position.tap()
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (position.value as? String)?.hasPrefix("settled-") == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 10), .completed)
        guard prepareDraft("中文 Lift 你好", app: app) else { return }
        let editor = app.textViews["conversation-composer-input"]
        let saved = editor.value as? String
        let reading = app.buttons["conversation-reading-test-inject-delta"].value as? String
        let anchor = app.staticTexts["OLDER_READING_POSITION_ANCHOR_TURN_10"]
        XCTAssertTrue(anchor.exists && anchor.isHittable)
        let originalAnchor = anchor.frame
        let start = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: 0, dy: -220))
        start.press(forDuration: 0.7, thenDragTo: end)
        guard waitForPhase("card", app: app) else { return }
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 0)
        let current = app.descendants(matching: .any)["workspace-current-card"]
        XCTAssertTrue(current.exists)
        current.tap()
        guard waitForPhase("full", app: app) else { return }
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 1)
        XCTAssertEqual(editor.value as? String, saved)
        XCTAssertEqual(app.buttons["conversation-reading-test-inject-delta"].value as? String, reading)
        XCTAssertTrue(anchor.isHittable)
        XCTAssertEqual(anchor.frame.minY, originalAnchor.minY, accuracy: 3)
        XCTAssertEqual(anchor.frame.height, originalAnchor.height, accuracy: 3)
    }

    @MainActor
    func testEditingLongPressNeverLiftsOrDiscardsText() {
        let app = launch()
        guard waitForPhase("full", app: app) else { return }
        let editor = app.textViews["conversation-composer-input"]
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        editor.typeText("正在编辑 你好")
        XCTAssertTrue(waitForText("正在编辑 你好", editor: editor))
        editor.press(forDuration: 0.7)
        XCTAssertTrue(waitForPhase("full", app: app))
        XCTAssertTrue((editor.value as? String)?.contains("正在编辑 你好") == true)
        XCTAssertFalse(app.descendants(matching: .any)["workspace-current-card"].exists)
    }

    @MainActor
    func testComposerDragTargetsTopSplit() {
        assertSplitTarget(.init(dx: 0.5, dy: 0.18), expected: "top")
    }

    @MainActor
    func testComposerDragTargetsBottomSplit() {
        assertSplitTarget(.init(dx: 0.5, dy: 0.56), expected: "bottom")
    }

    @MainActor
    private func assertSplitTarget(_ destination: CGVector, expected slot: String) {
        let app = launch()
        guard waitForPhase("full", app: app) else { return }
        let position = app.buttons["conversation-reading-test-position-older-turn"]
        guard position.waitForExistence(timeout: 10) else { XCTFail("Reading fixture missing"); return }
        position.tap()
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (position.value as? String)?.hasPrefix("settled-") == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 10), .completed)
        guard prepareDraft("Split 草稿", app: app) else { return }
        let editor = app.textViews["conversation-composer-input"]
        let saved = editor.value as? String
        let anchor = app.staticTexts["OLDER_READING_POSITION_ANCHOR_TURN_10"]
        XCTAssertTrue(anchor.exists && anchor.isHittable)
        let originalAnchor = anchor.frame
        let start = editor.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: destination)
        start.press(forDuration: 0.7, thenDragTo: end)
        let probe = app.otherElements["split-drop-intent-probe"]
        guard probe.waitForExistence(timeout: 10) else {
            XCTFail("A real Composer drag must report its Split target")
            return
        }
        XCTAssertEqual(probe.value as? String, slot)
        XCTAssertTrue(waitForPhase("full", app: app), "Until a Split consumer is installed, release returns to Full")
        XCTAssertEqual(editor.value as? String, saved)
        XCTAssertTrue(anchor.isHittable)
        XCTAssertEqual(anchor.frame.minY, originalAnchor.minY, accuracy: 3)
        XCTAssertEqual(anchor.frame.height, originalAnchor.height, accuracy: 3)
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_SURFACE_LIFT_UI_TEST"] = "1"
        app.launch()
        return app
    }

    @MainActor
    private func waitForPhase(_ phase: String, app: XCUIApplication) -> Bool {
        let probe = app.otherElements["surface-lift-state-probe"]
        guard probe.waitForExistence(timeout: 15) else {
            XCTFail("The actual Workspace fixture must expose its presentation state")
            return false
        }
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (probe.value as? String) == phase
        }, object: nil)
        let result = XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
        XCTAssertTrue(result, "Expected actual phase \(phase), got \(String(describing: probe.value))")
        return result
    }

    @MainActor
    private func waitForText(_ text: String, editor: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (editor.value as? String)?.contains(text) == true
        }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
    }

    @MainActor
    private func prepareDraft(_ text: String, app: XCUIApplication) -> Bool {
        let editor = app.textViews["conversation-composer-input"]
        guard editor.waitForExistence(timeout: 10) else { XCTFail("Existing editor missing"); return false }
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        editor.typeText(text)
        let ready = waitForText(text, editor: editor)
        XCTAssertTrue(ready)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.25)).tap()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !app.keyboards.firstMatch.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 10), .completed)
        return ready
    }
}

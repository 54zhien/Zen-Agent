import XCTest

final class PreviewHandoffUITests: XCTestCase {
    @MainActor
    func testProductionLiftDismantlesEditorAndRepeatedReturnPreservesDraft() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launch()
        let editor = app.textViews["conversation-composer-input"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        editor.typeText("中文 Preview draft")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.25)).tap()
        expect({ !app.keyboards.firstMatch.exists })
        let saved = editor.value as? String
        XCTAssertTrue(saved?.contains("中文 Preview draft") == true)
        for _ in 0..<3 {
            let start = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.7, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -220)))
            expect { (app.otherElements["surface-lift-state-probe"].value as? String) == "card" }
            XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 0)
            let card = app.descendants(matching: .any)["workspace-current-card"]
            XCTAssertTrue(card.exists)
            XCTAssertTrue(card.label.contains("Workspace conversation 11"))
            card.tap()
            expect { (app.otherElements["surface-lift-state-probe"].value as? String) == "full" }
            XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 1)
            XCTAssertEqual(editor.value as? String, saved)
        }
    }

    @MainActor
    func testPersistedReadingAnchorRestoresAfterNativeContentRemount() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launch()
        let position = app.buttons["preview-reading-position"]
        XCTAssertTrue(position.waitForExistence(timeout: 15))
        position.tap()
        expect { (position.value as? String) == "settled" }
        let anchor = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ OR value == %@", "PREVIEW_READING_ANCHOR_10", "PREVIEW_READING_ANCHOR_10")).firstMatch
        XCTAssertTrue(anchor.exists && anchor.isHittable)
        let original = anchor.frame
        let editor = app.textViews["conversation-composer-input"]
        let start = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.7, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -220)))
        expect { (app.otherElements["surface-lift-state-probe"].value as? String) == "card" }
        XCTAssertEqual(app.textViews.count, 0)
        app.descendants(matching: .any)["workspace-current-card"].tap()
        expect { (app.otherElements["surface-lift-state-probe"].value as? String) == "full" }
        expect { (position.value as? String) == "settled" && anchor.isHittable }
        XCTAssertEqual(anchor.frame.minY, original.minY, accuracy: 3)
        XCTAssertEqual(anchor.frame.height, original.height, accuracy: 3)
    }

    @MainActor
    private func expect(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let pending = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [pending], timeout: 10), .completed, file: file, line: line)
    }
}

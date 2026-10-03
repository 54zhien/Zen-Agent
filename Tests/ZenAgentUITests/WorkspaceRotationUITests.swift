import XCTest

final class WorkspaceRotationUITests: XCTestCase {
    @MainActor
    func testLandscapeEditsBelongToTheLastActivePaneAndPortraitRestoresBoth() {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = occupiedSplit()
        let source = app.scrollViews.matching(identifier: "conversation-pane-preview-ui-11").firstMatch
        let secondary = app.scrollViews.matching(identifier: "conversation-pane-preview-ui-10").firstMatch
        let sourceEditor = app.textViews.matching(identifier: "conversation-composer-input").element(boundBy: 0)
        sourceEditor.tap()
        sourceEditor.typeText("source portrait draft")
        dismissKeyboard(app, pane: source)
        let secondaryEditor = app.textViews.matching(identifier: "conversation-composer-input").element(boundBy: 1)
        secondaryEditor.tap()
        secondaryEditor.typeText("secondary portrait draft")
        dismissKeyboard(app, pane: secondary)
        let sourceHeight = source.frame.height
        let secondaryHeight = secondary.frame.height

        XCUIDevice.shared.orientation = .landscapeLeft
        expect { app.frame.width > app.frame.height }
        expect { app.textViews.matching(identifier: "conversation-composer-input").count == 1 }
        let landscapeEditor = app.textViews["conversation-composer-input"]
        XCTAssertTrue(secondary.exists && landscapeEditor.isHittable)
        XCTAssertFalse(source.exists)
        landscapeEditor.tap()
        landscapeEditor.typeText(" landscape edit")
        dismissKeyboard(app, pane: secondary)

        XCUIDevice.shared.orientation = .portrait
        expect { app.textViews.matching(identifier: "conversation-composer-input").count == 2 }
        XCTAssertEqual(sourceEditor.value as? String, "source portrait draft")
        XCTAssertEqual(secondaryEditor.value as? String, "secondary portrait draft landscape edit")
        XCTAssertEqual(source.frame.height, sourceHeight, accuracy: 3)
        XCTAssertEqual(secondary.frame.height, secondaryHeight, accuracy: 3)
    }

    @MainActor
    func testLandscapeCardStackReturnsToTheSelectedExistingPaneWithoutDuplicatingIt() {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = occupiedSplit()
        let editor = app.textViews.matching(identifier: "conversation-composer-input").element(boundBy: 1)
        let start = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.7, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -220)))
        let card = app.descendants(matching: .any)["workspace-current-card"]
        expect { card.exists && card.label.contains("Workspace conversation 10") }
        XCUIDevice.shared.orientation = .landscapeLeft
        expect { app.frame.width > app.frame.height && card.exists }
        XCTAssertTrue(card.label.contains("Workspace conversation 10"))
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 0)
        XCTAssertTrue(app.frame.contains(card.frame))
        card.swipeLeft()
        expect { card.label.contains("Workspace conversation 11") }
        card.tap()
        expect { app.textViews.matching(identifier: "conversation-composer-input").count == 1 }
        let source = app.scrollViews.matching(identifier: "conversation-pane-preview-ui-11").firstMatch
        XCTAssertTrue(source.exists && app.textViews["conversation-composer-input"].isHittable)

        XCUIDevice.shared.orientation = .portrait
        expect { app.textViews.matching(identifier: "conversation-composer-input").count == 2 }
        XCTAssertTrue(source.exists)
        XCTAssertTrue(app.scrollViews.matching(identifier: "conversation-pane-preview-ui-10").firstMatch.exists)
    }

    @MainActor
    private func occupiedSplit() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launch()
        let entry = app.buttons["split-entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15))
        entry.tap()
        app.buttons["split-open-top"].tap()
        let history = app.buttons["split-history-preview-ui-10"]
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        history.tap()
        expect { app.textViews.matching(identifier: "conversation-composer-input").count == 2 }
        return app
    }

    @MainActor
    private func dismissKeyboard(_ app: XCUIApplication, pane: XCUIElement) {
        pane.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.25)).tap()
        expect { !app.keyboards.firstMatch.exists }
    }

    @MainActor
    private func expect(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let pending = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [pending], timeout: 10), .completed, file: file, line: line)
    }
}

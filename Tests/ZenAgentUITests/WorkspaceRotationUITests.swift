import XCTest

final class WorkspaceRotationUITests: XCTestCase {
    @MainActor
    func testLandscapeEditsBelongToTheLastActivePaneAndPortraitRestoresBoth() {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = occupiedSplit()
        let source = app.scrollViews.matching(identifier: "conversation-pane-preview-ui-11").firstMatch
        let secondary = app.scrollViews.matching(identifier: "conversation-pane-preview-ui-10").firstMatch
        let initialEditor = app.textViews.matching(identifier: "conversation-composer-input").element(boundBy: 0)
        initialEditor.tap()
        initialEditor.typeText("source portrait draft")
        let sourceEditor = editor(in: app, containing: "source portrait draft")
        XCTAssertTrue(sourceEditor.waitForExistence(timeout: 5))
        dismissKeyboard(app, pane: source, editor: sourceEditor)
        let secondaryProbe = app.descendants(matching: .any)["split-secondary-native-interaction-probe"]
        let sourceProbe = app.descendants(matching: .any)["surface-native-interaction-probe"]
        XCTAssertEqual(editorTextLength(sourceProbe.value as? String), "source portrait draft".utf16.count)
        XCTAssertEqual(editorTextLength(secondaryProbe.value as? String), 0)
        guard let point = editorPoint(secondaryProbe.value as? String) else {
            XCTFail("Secondary native editor geometry must be available")
            return
        }
        app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: point.x - app.frame.minX, dy: point.y - app.frame.minY)).tap()
        expect { (secondaryProbe.value as? String)?.contains(";focused=true;") == true }
        app.typeText("secondary portrait draft")
        XCTAssertEqual(editorTextLength(sourceProbe.value as? String), "source portrait draft".utf16.count)
        XCTAssertEqual(editorTextLength(secondaryProbe.value as? String), "secondary portrait draft".utf16.count)
        let secondaryEditor = editor(in: app, containing: "secondary portrait draft")
        XCTAssertTrue(secondaryEditor.waitForExistence(timeout: 5))
        dismissKeyboard(app, pane: secondary, editor: secondaryEditor)
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
        dismissKeyboard(app, pane: secondary, editor: landscapeEditor)

        XCUIDevice.shared.orientation = .portrait
        expect { app.textViews.matching(identifier: "conversation-composer-input").count == 2 }
        XCTAssertTrue((sourceEditor.value as? String) == "source portrait draft"
            || sourceEditor.label == "source portrait draft")
        let editedSecondary = editor(in: app, containing: "secondary portrait draft landscape edit")
        XCTAssertTrue(editedSecondary.exists)
        XCTAssertEqual(editorTextLength(sourceProbe.value as? String), "source portrait draft".utf16.count)
        XCTAssertEqual(editorTextLength(secondaryProbe.value as? String), "secondary portrait draft landscape edit".utf16.count)
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
    private func dismissKeyboard(_ app: XCUIApplication, pane: XCUIElement, editor: XCUIElement) {
        let blankY = editor.frame.minY - 30
        XCTAssertGreaterThan(blankY, pane.frame.minY)
        XCTAssertLessThan(blankY, app.keyboards.firstMatch.frame.minY)
        app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: pane.frame.maxX - 8 - app.frame.minX, dy: blankY - app.frame.minY)).tap()
        expect { !app.keyboards.firstMatch.exists }
    }

    private func editorPoint(_ diagnostic: String?) -> CGPoint? {
        guard let field = diagnostic?.split(separator: ";").first(where: { $0.hasPrefix("point=(") }) else { return nil }
        let values = field.dropFirst(7).dropLast().split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard values.count == 2 else { return nil }
        return CGPoint(x: values[0], y: values[1])
    }

    @MainActor
    private func editor(in app: XCUIApplication, containing draft: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND (value CONTAINS %@ OR label CONTAINS %@)",
            "conversation-composer-input", draft, draft)).firstMatch
    }

    private func editorTextLength(_ diagnostic: String?) -> Int? {
        diagnostic?.split(separator: ";").first { $0.hasPrefix("editorTextLength=") }
            .flatMap { Int($0.dropFirst("editorTextLength=".count)) }
    }

    @MainActor
    private func expect(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let pending = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [pending], timeout: 10), .completed, file: file, line: line)
    }
}

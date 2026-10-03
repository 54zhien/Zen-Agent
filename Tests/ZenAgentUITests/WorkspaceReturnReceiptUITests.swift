import XCTest

final class WorkspaceReturnReceiptUITests: XCTestCase {
    @MainActor
    func testOccupiedOwnerMeasuresWhileItsEditorRemainsOutsideAccessibility() throws {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        // Pause only after the production native layout/scroll receipt. The
        // seam must not supply a fake receipt or directly change a Pane owner.
        app.launchEnvironment["ZEN_RETURN_RECEIPT_PAUSE_UI_TEST"] = "1"
        app.launch()
        let entry = app.buttons["split-entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15))
        entry.tap()
        app.buttons["split-open-top"].tap()
        let history = app.buttons["split-history-preview-ui-10"]
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        history.tap()
        expect { app.textViews.matching(identifier: "conversation-composer-input").count == 2 }
        let targetProbe = app.descendants(matching: .any)["surface-native-interaction-probe"]
        let targetIdentity = try XCTUnwrap(editorIdentity(targetProbe.value as? String))
        let originProbe = app.descendants(matching: .any)["split-secondary-native-interaction-probe"]
        expect { (originProbe.value as? String)?.contains("liftReady=true;") == true }
        let originEditor = app.textViews.matching(identifier: "conversation-composer-input").element(boundBy: 1)
        let start = originEditor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.7, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -220)))
        let card = app.descendants(matching: .any)["workspace-current-card"]
        expect { card.exists && card.label.contains("Workspace conversation 10") }
        XCUIDevice.shared.orientation = .landscapeLeft
        expect { app.frame.width > app.frame.height && card.exists }
        card.swipeLeft()
        expect { card.label.contains("Workspace conversation 11") }
        card.tap()
        let resume = app.buttons["workspace-return-resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        XCTAssertEqual(resume.value as? String, "ready")
        XCTAssertTrue(card.exists && card.label.contains("Workspace conversation 11"))
        XCTAssertEqual(app.descendants(matching: .any)
            .matching(identifier: "conversation-composer-input").count, 0)
        let receipt = try XCTUnwrap(targetProbe.value as? String)
        XCTAssertTrue(receipt.contains(";visible=true;"))
        XCTAssertTrue(receipt.contains(";editors=1;"))
        XCTAssertTrue(receipt.contains(";contentInteraction=false;"))
        XCTAssertTrue(receipt.contains(";contentAXHidden=true;"))
        XCTAssertTrue(receipt.contains("ready=true;"))
        XCTAssertTrue(receipt.contains(";request=nil;"))
        XCTAssertEqual(editorIdentity(receipt), targetIdentity)
        let targetFrame = try XCTUnwrap(hostFrame(receipt))
        XCTAssertEqual(targetFrame.minX, app.frame.minX, accuracy: 3)
        XCTAssertEqual(targetFrame.minY, app.frame.minY, accuracy: 3)
        XCTAssertEqual(targetFrame.width, app.frame.width, accuracy: 3)
        XCTAssertEqual(targetFrame.height, app.frame.height, accuracy: 3)
        resume.tap()
        expect { !resume.exists && !card.exists
            && app.textViews.matching(identifier: "conversation-composer-input").count == 1 }
        XCTAssertTrue(app.scrollViews.matching(identifier: "conversation-pane-preview-ui-11").firstMatch.exists)
        XCTAssertEqual(editorIdentity(targetProbe.value as? String), targetIdentity)
        let editor = app.textViews["conversation-composer-input"]
        editor.tap()
        editor.typeText("selected owner after receipt")
        XCTAssertTrue((editor.value as? String)?.contains("selected owner after receipt") == true)
    }

    private func editorIdentity(_ diagnostic: String?) -> String? {
        diagnostic?.split(separator: ";").first { $0.hasPrefix("editorIdentity=") }.map(String.init)
    }

    private func hostFrame(_ diagnostic: String) -> CGRect? {
        guard let field = diagnostic.split(separator: ";").first(where: { $0.hasPrefix("hostFrame=(") }) else { return nil }
        let values = field.dropFirst("hostFrame=(".count).dropLast().split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard values.count == 4 else { return nil }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    @MainActor
    private func expect(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let pending = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [pending], timeout: 10), .completed, file: file, line: line)
    }
}

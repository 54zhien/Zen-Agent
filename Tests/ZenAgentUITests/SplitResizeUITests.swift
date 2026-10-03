import XCTest

final class SplitResizeUITests: XCTestCase {
    @MainActor
    func testExplicitCloseTopKeepsTheSecondaryConversationEditable() {
        closePane(action: "关闭上方窗格", survivorID: "preview-ui-10", retiredID: "preview-ui-11")
    }

    @MainActor
    func testExplicitCloseBottomKeepsTheSourceConversationEditable() {
        closePane(action: "关闭下方窗格", survivorID: "preview-ui-11", retiredID: "preview-ui-10")
    }

    @MainActor
    private func closePane(action: String, survivorID: String, retiredID: String) {
        let app = occupiedSplit()
        let probeID = survivorID == "preview-ui-10"
            ? "split-secondary-native-interaction-probe" : "surface-native-interaction-probe"
        let probe = app.descendants(matching: .any)[probeID]
        let beforeIdentity = editorIdentity(probe.value as? String)
        XCTAssertNotNil(beforeIdentity, "The probe must identify the actual native editor before closure")
        let divider = app.descendants(matching: .any)["split-divider"]
        divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.8)
        let close = app.buttons[action]
        guard close.waitForExistence(timeout: 5) else {
            XCTFail("Divider Handle needs an explicit close action for each Pane")
            return
        }
        close.tap()
        expect { !divider.exists && app.textViews.matching(identifier: "conversation-composer-input").count == 1 }
        XCTAssertTrue(app.scrollViews.matching(identifier: "conversation-pane-\(survivorID)").firstMatch.exists)
        XCTAssertFalse(app.scrollViews.matching(identifier: "conversation-pane-\(retiredID)").firstMatch.exists)
        XCTAssertEqual(editorIdentity(probe.value as? String), beforeIdentity,
                       "Closing the opposite Pane must retain the survivor's actual UITextView")
        let editor = app.textViews["conversation-composer-input"]
        editor.tap()
        editor.typeText("survivor after explicit close")
        XCTAssertTrue((editor.value as? String)?.contains("survivor after explicit close") == true)
    }

    @MainActor
    func testResizingAReadingPaneKeepsTheVisibleTurnAtItsBottomDistance() {
        let app = occupiedSplit()
        let position = app.buttons["preview-reading-position"]
        position.tap()
        expect { (position.value as? String) == "settled" }
        let anchor = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ OR value == %@", "PREVIEW_READING_ANCHOR_10",
            "PREVIEW_READING_ANCHOR_10")).firstMatch
        XCTAssertTrue(anchor.exists && anchor.isHittable)
        let pane = app.scrollViews.matching(identifier: "conversation-pane-preview-ui-11").firstMatch
        let bottomDistance = pane.frame.maxY - anchor.frame.minY
        let initialHeight = pane.frame.height
        let divider = app.descendants(matching: .any)["split-divider"]
        let handle = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        handle.press(forDuration: 0.15, thenDragTo: handle.withOffset(CGVector(dx: 0, dy: 70)))
        expect { pane.frame.height > initialHeight + 30 }
        expect { anchor.isHittable && abs(pane.frame.maxY - anchor.frame.minY - bottomDistance) < 4 }
        let grownHeight = pane.frame.height
        printDiagnostics(app, context: "after first resize")
        let movedHandle = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        movedHandle.press(forDuration: 0.15,
                          thenDragTo: movedHandle.withOffset(CGVector(dx: 0, dy: -50)))
        expect { pane.frame.height < grownHeight - 20 }
        printDiagnostics(app, context: "after second resize")
        XCTAssertEqual(pane.frame.maxY - anchor.frame.minY, bottomDistance, accuracy: 4)
    }

    @MainActor
    func testHandleResizeChangesBothPaneHeightsAndPreservesTheirDrafts() {
        let app = occupiedSplit()
        let source = app.scrollViews.matching(identifier: "conversation-pane-preview-ui-11").firstMatch
        let secondary = app.scrollViews.matching(identifier: "conversation-pane-preview-ui-10").firstMatch
        let sourceEditor = app.textViews.matching(identifier: "conversation-composer-input").element(boundBy: 0)
        sourceEditor.tap()
        sourceEditor.typeText("source resize draft")
        dismissKeyboard(in: app, pane: source)
        let secondaryEditor = app.textViews.matching(identifier: "conversation-composer-input").element(boundBy: 1)
        secondaryEditor.tap()
        secondaryEditor.typeText("secondary resize draft")
        dismissKeyboard(in: app, pane: secondary)

        let sourceBefore = source.frame
        let secondaryBefore = secondary.frame
        let divider = app.descendants(matching: .any)["split-divider"]
        let handle = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        handle.press(forDuration: 0.15, thenDragTo: handle.withOffset(CGVector(dx: 0, dy: 75)))
        expect { source.frame.height > sourceBefore.height + 30 }
        XCTAssertLessThan(secondary.frame.height, secondaryBefore.height - 30)
        XCTAssertEqual(source.frame.height + secondary.frame.height,
                       sourceBefore.height + secondaryBefore.height, accuracy: 3)
        XCTAssertTrue((sourceEditor.value as? String)?.contains("source resize draft") == true)
        XCTAssertTrue((secondaryEditor.value as? String)?.contains("secondary resize draft") == true)
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 2)
    }

    @MainActor
    func testDividerLineOutsideHandleDoesNotResizeOrCloseSplit() {
        let app = occupiedSplit()
        let source = app.scrollViews.matching(identifier: "conversation-pane-preview-ui-11").firstMatch
        let secondary = app.scrollViews.matching(identifier: "conversation-pane-preview-ui-10").firstMatch
        let before = source.frame
        let divider = app.descendants(matching: .any)["split-divider"]
        let line = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5))
        line.press(forDuration: 0.15, thenDragTo: line.withOffset(CGVector(dx: 0, dy: 80)))
        XCTAssertEqual(source.frame.height, before.height, accuracy: 3)
        line.tap()
        XCTAssertTrue(divider.exists)
        XCTAssertTrue(secondary.exists)
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 2)
    }

    private func editorIdentity(_ diagnostic: String?) -> String? {
        diagnostic?.split(separator: ";").first { $0.hasPrefix("editorIdentity=") }.map(String.init)
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
    private func dismissKeyboard(in app: XCUIApplication, pane: XCUIElement) {
        pane.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.25)).tap()
        expect { !app.keyboards.firstMatch.exists }
        printDiagnostics(app, context: "after blank tap")
    }

    @MainActor
    private func printDiagnostics(_ app: XCUIApplication, context: String) {
        for id in ["surface-native-interaction-probe", "split-secondary-native-interaction-probe"] {
            let probe = app.descendants(matching: .any)[id]
            print("RESIZE_DIAGNOSTIC \(context) \(id): \(probe.exists ? probe.value as? String ?? "no value" : "missing")")
        }
    }

    @MainActor
    private func expect(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let pending = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [pending], timeout: 10), .completed, file: file, line: line)
    }
}

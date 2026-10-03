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
        let sourceProbe = app.descendants(matching: .any)["surface-native-interaction-probe"]
        let secondaryProbe = app.descendants(matching: .any)["split-secondary-native-interaction-probe"]
        let sourceIdentity = editorIdentity(sourceProbe.value as? String)
        let secondaryIdentity = editorIdentity(secondaryProbe.value as? String)
        XCTAssertNotNil(sourceIdentity, "The source probe must identify its actual native editor")
        XCTAssertNotNil(secondaryIdentity, "The secondary probe must identify its actual native editor")
        let initialEditor = app.textViews.matching(identifier: "conversation-composer-input").element(boundBy: 0)
        initialEditor.tap()
        initialEditor.typeText("source resize draft")
        let sourceEditor = editor(in: app, containing: "source resize draft")
        XCTAssertTrue(sourceEditor.waitForExistence(timeout: 5))
        dismissKeyboard(in: app, pane: source, editor: sourceEditor)
        XCTAssertEqual(editorTextLength(sourceProbe.value as? String), "source resize draft".utf16.count)
        XCTAssertEqual(editorTextLength(secondaryProbe.value as? String), 0)
        // The empty resting editor need not be a separate AX text-view node.
        // Tap its real native location, then type through the actual first responder.
        guard let point = editorPoint(secondaryProbe.value as? String) else {
            XCTFail("The secondary Surface must retain its native editor geometry")
            return
        }
        app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: point.x - app.frame.minX, dy: point.y - app.frame.minY)).tap()
        expect { (secondaryProbe.value as? String)?.contains(";focused=true;") == true }
        app.typeText("secondary resize draft")
        printDiagnostics(app, context: "after secondary input")
        XCTAssertEqual(editorTextLength(sourceProbe.value as? String), "source resize draft".utf16.count)
        XCTAssertEqual(editorTextLength(secondaryProbe.value as? String), "secondary resize draft".utf16.count)
        let nativeFrame = editorFrame(secondaryProbe.value as? String)
        let lineHeight = editorLineHeight(secondaryProbe.value as? String)
        XCTAssertNotNil(nativeFrame)
        XCTAssertNotNil(lineHeight)
        XCTAssertGreaterThanOrEqual(nativeFrame?.height ?? 0, lineHeight ?? 1,
            "The focused native editor must expose at least one readable line")
        XCTAssertGreaterThanOrEqual(timelineHeight(sourceProbe.value as? String) ?? 0,
            editorLineHeight(sourceProbe.value as? String) ?? 1,
            "The inactive Pane must remain readable while the other Pane edits")
        XCTAssertGreaterThanOrEqual(timelineHeight(secondaryProbe.value as? String) ?? 0,
            lineHeight ?? 1, "The editing Pane must retain a readable Timeline viewport")
        let secondaryEditor = editor(in: app, containing: "secondary resize draft")
        XCTAssertTrue(secondaryEditor.waitForExistence(timeout: 5))
        dismissKeyboard(in: app, pane: secondary, editor: secondaryEditor)

        let sourceBefore = source.frame
        let secondaryBefore = secondary.frame
        let divider = app.descendants(matching: .any)["split-divider"]
        let handle = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        handle.press(forDuration: 0.15, thenDragTo: handle.withOffset(CGVector(dx: 0, dy: 75)))
        expect { source.frame.height > sourceBefore.height + 30 }
        XCTAssertLessThan(secondary.frame.height, secondaryBefore.height - 30)
        XCTAssertEqual(source.frame.height + secondary.frame.height,
                       sourceBefore.height + secondaryBefore.height, accuracy: 3)
        XCTAssertTrue((sourceEditor.value as? String)?.contains("source resize draft") == true
            || sourceEditor.label.contains("source resize draft"))
        XCTAssertTrue((secondaryEditor.value as? String)?.contains("secondary resize draft") == true
            || secondaryEditor.label.contains("secondary resize draft"))
        XCTAssertTrue((sourceProbe.value as? String)?.contains(";editors=1;") == true)
        XCTAssertTrue((secondaryProbe.value as? String)?.contains(";editors=1;") == true)
        XCTAssertEqual(editorIdentity(sourceProbe.value as? String), sourceIdentity)
        XCTAssertEqual(editorIdentity(secondaryProbe.value as? String), secondaryIdentity)
        XCTAssertEqual(editorTextLength(sourceProbe.value as? String), "source resize draft".utf16.count)
        XCTAssertEqual(editorTextLength(secondaryProbe.value as? String), "secondary resize draft".utf16.count)
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

    private func editorTextLength(_ diagnostic: String?) -> Int? {
        diagnostic?.split(separator: ";").first { $0.hasPrefix("editorTextLength=") }
            .flatMap { Int($0.dropFirst("editorTextLength=".count)) }
    }

    private func editorFrame(_ diagnostic: String?) -> CGRect? {
        guard let field = diagnostic?.split(separator: ";").first(where: { $0.hasPrefix("editorFrame=(") }) else { return nil }
        let values = field.dropFirst("editorFrame=(".count).dropLast().split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard values.count == 4 else { return nil }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    private func editorLineHeight(_ diagnostic: String?) -> CGFloat? {
        guard let field = diagnostic?.split(separator: ";").first(where: {
            $0.hasPrefix("editorLineHeight=")
        }), let value = Double(field.dropFirst("editorLineHeight=".count)) else { return nil }
        return CGFloat(value)
    }

    private func timelineHeight(_ diagnostic: String?) -> CGFloat? {
        guard let field = diagnostic?.split(separator: ";").first(where: {
            $0.hasPrefix("container=(")
        }) else { return nil }
        let values = field.dropFirst("container=(".count).dropLast().split(separator: ",")
        guard values.count == 2,
              let height = Double(values[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        return CGFloat(height)
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
        // UIKit can expose a clipped UITextView through a paragraph AX element.
        // Verify the actual user-entered value without assuming its automation type;
        // the native probes separately assert editor identity and ownership.
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND (value CONTAINS %@ OR label CONTAINS %@)",
            "conversation-composer-input", draft, draft)).firstMatch
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
    private func dismissKeyboard(in app: XCUIApplication, pane: XCUIElement, editor: XCUIElement) {
        // Pane AX bounds include the large navigation title. Use the Timeline
        // margin directly above the actual Composer, outside padded Turn content.
        let blankY = editor.frame.minY - 30
        XCTAssertGreaterThan(blankY, pane.frame.minY + 120)
        XCTAssertLessThan(blankY, app.keyboards.firstMatch.frame.minY)
        let point = app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: pane.frame.maxX - 8 - app.frame.minX, dy: blankY - app.frame.minY))
        print("RESIZE_BLANK_POINT pane=\(pane.frame) point=\(point.screenPoint) keyboard=\(app.keyboards.firstMatch.frame)")
        point.tap()
        expect { !app.keyboards.firstMatch.exists }
        printDiagnostics(app, context: "after blank tap")
    }

    @MainActor
    private func printDiagnostics(_ app: XCUIApplication, context: String) {
        for id in ["split-viewport-probe", "surface-native-interaction-probe", "split-secondary-native-interaction-probe"] {
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

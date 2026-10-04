import XCTest

final class ConversationSearchUITests: XCTestCase {
    @MainActor
    func testPlainExitRestoresTheSameNativeEditingOwner() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["split-entry"].waitForExistence(timeout: 15))
        let editor = app.textViews["conversation-composer-input"]
        let probe = app.descendants(matching: .any)["surface-native-interaction-probe"]
        editor.tap()
        editor.typeText("focused Search draft")
        expect { app.keyboards.firstMatch.exists
            && (probe.value as? String)?.contains("focused=true;") == true }
        let identity = editorIdentity(probe.value as? String)
        XCTAssertNotNil(identity)
        guard openSearch(app) else { return }
        let input = app.textFields["conversation-search-input"]
        guard input.waitForExistence(timeout: 5), input.wait(for: \.isHittable, toEqual: true, timeout: 5) else {
            XCTFail("Search input did not appear after opening Search")
            return
        }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["conversation-search-close"].tap()
        expect { editor.exists }
        print("SEARCH_EXIT_NATIVE \(probe.value as? String ?? "missing")")
        expect { (probe.value as? String)?.contains("focused=true;") == true }
        print("SEARCH_EXIT_NATIVE_SETTLED \(probe.value as? String ?? "missing")")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(editorIdentity(probe.value as? String), identity)
        XCTAssertTrue((editor.value as? String)?.contains("focused Search draft") == true)
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 1)
        XCTAssertFalse(input.exists)
        let pane = app.scrollViews.matching(identifier: "conversation-pane-preview-ui-11").firstMatch
        app.dismissWorkspaceKeyboard(pane: pane, editor: editor)
    }

    @MainActor
    func testExitRestoresTheOriginalDraftAndSelectionOpensTheResult() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["split-entry"].waitForExistence(timeout: 15))
        let editor = app.textViews["conversation-composer-input"]
        editor.tap()
        editor.typeText("draft retained through Search")
        let pane = app.scrollViews.matching(identifier: "conversation-pane-preview-ui-11").firstMatch
        app.dismissWorkspaceKeyboard(pane: pane, editor: editor)
        guard openSearch(app) else { return }
        let input = app.textFields["conversation-search-input"]
        guard input.waitForExistence(timeout: 5), input.wait(for: \.isHittable, toEqual: true, timeout: 5) else {
            XCTFail("Search input did not appear after opening Search")
            return
        }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let geometry = app.descendants(matching: .any)["search-native-keyboard-geometry"]
        expect { (self.keyboardFrame(geometry.value as? String)?.height ?? 0) > 0 }
        guard let keyboard = keyboardFrame(geometry.value as? String), keyboard.height > 0 else {
            XCTFail("Missing actual native keyboard occlusion geometry")
            return
        }
        print("SEARCH_KEYBOARD_FRAME input=\(input.frame);AX=\(app.keyboards.firstMatch.frame);native=\(keyboard)")
        XCTAssertLessThan(abs(input.frame.maxY - keyboard.minY), 28)
        app.buttons["conversation-search-close"].tap()
        expect { !input.exists }
        XCTAssertTrue((editor.value as? String)?.contains("draft retained through Search") == true)
        guard openSearch(app) else { return }
        guard input.waitForExistence(timeout: 5),
              input.wait(for: \.isHittable, toEqual: true, timeout: 5),
              app.keyboards.firstMatch.waitForExistence(timeout: 5) else {
            XCTFail("Reopened Search input is not ready")
            return
        }
        input.typeText("Workspace conversation 3")
        let result = app.buttons["conversation-search-result-preview-ui-3"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["conversation-search-result-preview-ui-11"].exists)
        result.tap()
        let target = app.scrollViews.matching(identifier: "conversation-pane-preview-ui-3").firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        XCTAssertFalse(input.exists)
        XCTAssertFalse(app.descendants(matching: .any)["sidebar-rail"].exists)
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 1)
        let targetProbe = app.descendants(matching: .any)["surface-native-interaction-probe"]
        expect { !app.keyboards.firstMatch.exists
            && (targetProbe.value as? String)?.contains("focused=false;") == true }
    }

    @MainActor
    private func openSearch(_ app: XCUIApplication) -> Bool {
        let probe = app.descendants(matching: .any)["surface-native-interaction-probe"]
        expect { (probe.value as? String)?.contains(";sidebarCanOpen=true;") == true }
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.001, dy: 0.3))
        edge.press(forDuration: 0.05, thenDragTo: edge.withOffset(CGVector(dx: 110, dy: 0)))
        let search = app.buttons["sidebar-search"]
        guard search.waitForExistence(timeout: 5),
              search.wait(for: \.isEnabled, toEqual: true, timeout: 5) else {
            XCTFail("Sidebar Search destination is unavailable")
            return false
        }
        guard let safeTop = (probe.value as? String)?.split(separator: ";")
            .first(where: { $0.hasPrefix("windowSafeTop=") })
            .flatMap({ Double($0.dropFirst("windowSafeTop=".count)) }), safeTop > 0 else {
            XCTFail("Missing the actual portrait Window safe-area receipt")
            return false
        }
        XCTAssertGreaterThanOrEqual(search.frame.minY, app.frame.minY + CGFloat(safeTop),
            "Search must be below the scene status bar")
        print("SEARCH_RAIL_FRAME \(search.frame); windowSafeTop=\(safeTop)")
        guard search.wait(for: \.isHittable, toEqual: true, timeout: 5) else {
            XCTFail("Sidebar Search destination is not hittable")
            return false
        }
        search.tap()
        return true
    }

    private func editorIdentity(_ diagnostic: String?) -> String? {
        diagnostic?.split(separator: ";").first { $0.hasPrefix("editorIdentity=") }.map(String.init)
    }

    private func keyboardFrame(_ diagnostic: String?) -> CGRect? {
        guard let fields = diagnostic?.split(separator: ";"),
              let top = fields.first(where: { $0.hasPrefix("top=") }).flatMap({ Double($0.dropFirst(4)) }),
              let height = fields.first(where: { $0.hasPrefix("height=") }).flatMap({ Double($0.dropFirst(7)) }),
              top.isFinite, height.isFinite else { return nil }
        return CGRect(x: 0, y: top, width: 0, height: height)
    }

    @MainActor
    private func expect(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let pending = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [pending], timeout: 10), .completed, file: file, line: line)
    }
}

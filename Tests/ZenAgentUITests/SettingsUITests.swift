import XCTest

final class SettingsUITests: XCTestCase {
    @MainActor
    func testSoulEditorCloseReturnsFocusToTheSameNativeConversationEditor() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["split-entry"].waitForExistence(timeout: 15))
        let editor = app.textViews["conversation-composer-input"]
        let probe = app.descendants(matching: .any)["surface-native-interaction-probe"]
        editor.tap()
        editor.typeText("focused Settings draft")
        expect { app.keyboards.firstMatch.exists
            && (probe.value as? String)?.contains("focused=true;") == true
            && (probe.value as? String)?.contains(";sidebarCanOpen=true;") == true }
        let identity = (probe.value as? String)?.split(separator: ";")
            .first(where: { $0.hasPrefix("editorIdentity=") }).map(String.init)
        XCTAssertNotNil(identity)
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.001, dy: 0.3))
        edge.press(forDuration: 0.05, thenDragTo: edge.withOffset(CGVector(dx: 110, dy: 0)))
        let destination = app.buttons["sidebar-settings"]
        guard destination.waitForExistence(timeout: 5),
              destination.wait(for: \.isEnabled, toEqual: true, timeout: 5),
              destination.wait(for: \.isHittable, toEqual: true, timeout: 5) else {
            XCTFail("Settings must be reachable while the original editor is focused")
            return
        }
        destination.tap()
        let page = app.descendants(matching: .any)["settings-page"]
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        let agent = app.buttons["settings-agent"]
        if !agent.isHittable { page.swipeUp() }
        agent.tap()
        app.buttons["settings-soul"].tap()
        let soul = app.textViews["settings-soul-instructions"]
        XCTAssertTrue(soul.waitForExistence(timeout: 5))
        soul.tap()
        soul.typeText("Unsaved Soul editor input")
        app.buttons["settings-close"].tap()
        expect { !page.exists && !soul.exists
            && app.keyboards.firstMatch.exists
            && (probe.value as? String)?.contains("focused=true;") == true }
        XCTAssertEqual((probe.value as? String)?.split(separator: ";")
            .first(where: { $0.hasPrefix("editorIdentity=") }).map(String.init), identity)
        XCTAssertTrue((editor.value as? String)?.contains("focused Settings draft") == true)
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 1)
        let pane = app.scrollViews.matching(identifier: "conversation-pane-preview-ui-11").firstMatch
        app.dismissWorkspaceKeyboard(pane: pane, editor: editor)
    }

    @MainActor
    func testEmptyStartupConfiguresItsNewOwnerThroughSettingsAndCommitsOnlyOnSend() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launchEnvironment["ZEN_NEW_CONFIGURE_UI_TEST"] = "1"
        app.launch()
        let configure = app.buttons["new-conversation-configure"]
        XCTAssertTrue(configure.waitForExistence(timeout: 15))
        let editor = app.textViews["conversation-composer-input"]
        editor.tap()
        editor.typeText("first Send keeps its original draft")
        let unavailableSend = app.buttons["conversation-composer-send"]
        XCTAssertFalse(unavailableSend.exists && unavailableSend.isEnabled)
        configure.tap()
        let settings = app.descendants(matching: .any)["settings-page"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        app.buttons["settings-providers"].tap()
        app.buttons["settings-provider-add"].tap()
        let key = app.secureTextFields["DeepSeek API Key"]
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        key.tap()
        key.typeText("settings-ui-fixture-key")
        app.buttons["保存配置"].tap()
        XCTAssertTrue(app.staticTexts["配置完成"].waitForExistence(timeout: 5))
        app.buttons["关闭"].tap()
        app.buttons["settings-close"].tap()
        expect { !settings.exists }
        XCTAssertTrue(configure.exists, "configuration alone must not commit the New Conversation")
        XCTAssertTrue((editor.value as? String)?.contains("first Send keeps its original draft") == true)
        let send = app.buttons["conversation-composer-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertTrue(send.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        send.tap()
        expect { !configure.exists }
        let probe = app.descendants(matching: .any)["surface-native-interaction-probe"]
        expect { (probe.value as? String)?.contains(";sidebarCanOpen=true;") == true }
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 1)
    }

    @MainActor
    func testSettingsReachesSoulAndClosingRestoresTheConversationDraft() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["split-entry"].waitForExistence(timeout: 15))
        let editor = app.textViews["conversation-composer-input"]
        editor.tap()
        editor.typeText("draft retained through Settings")
        let pane = app.scrollViews.matching(identifier: "conversation-pane-preview-ui-11").firstMatch
        app.dismissWorkspaceKeyboard(pane: pane, editor: editor)
        let probe = app.descendants(matching: .any)["surface-native-interaction-probe"]
        expect { (probe.value as? String)?.contains(";sidebarCanOpen=true;") == true }
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.001, dy: 0.3))
        edge.press(forDuration: 0.05, thenDragTo: edge.withOffset(CGVector(dx: 110, dy: 0)))
        let settings = app.buttons["sidebar-settings"]
        guard settings.waitForExistence(timeout: 5),
              settings.wait(for: \.isEnabled, toEqual: true, timeout: 5),
              settings.wait(for: \.isHittable, toEqual: true, timeout: 5) else {
            XCTFail("Sidebar Settings destination is unavailable")
            return
        }
        XCTAssertFalse(app.buttons["sidebar-agent"].exists)
        settings.tap()
        let page = app.descendants(matching: .any)["settings-page"]
        guard page.waitForExistence(timeout: 5) else {
            XCTFail("Settings page did not appear after opening Settings")
            return
        }
        XCTAssertFalse(app.descendants(matching: .any)["sidebar-rail"].exists)
        let agent = app.buttons["settings-agent"]
        if !agent.isHittable { page.swipeUp() }
        XCTAssertTrue(agent.waitForExistence(timeout: 5))
        agent.tap()
        let soul = app.buttons["settings-soul"]
        if !soul.isHittable { page.swipeUp() }
        XCTAssertTrue(soul.waitForExistence(timeout: 5))
        soul.tap()
        let input = app.textViews["settings-soul-instructions"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("Use concise responses.")
        app.buttons["settings-soul-save"].tap()
        let saved = app.staticTexts["settings-soul-save-status"]
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        XCTAssertTrue(saved.label.contains("已保存"))
        app.buttons["settings-close"].tap()
        expect { !page.exists }
        XCTAssertTrue((editor.value as? String)?.contains("draft retained through Settings") == true)
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 1)
    }

    @MainActor
    private func expect(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let pending = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [pending], timeout: 10), .completed, file: file, line: line)
    }
}

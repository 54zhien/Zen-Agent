import XCTest

final class MemorySettingsUITests: XCTestCase {
    @MainActor
    func testDarkMemorySwitchesAndConfirmedClearAll() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launchEnvironment["ZEN_MEMORY_UI_TEST"] = "seed"
        app.launchEnvironment["ZEN_MEMORY_UI_APPEARANCE"] = "dark"
        app.launch()
        XCTAssertTrue(app.textViews["conversation-composer-input"].waitForExistence(timeout: 15))
        guard openMemory(app) else { return }
        let enabled = app.switches["memory-enabled"], automatic = app.switches["memory-automatic"]
        XCTAssertTrue(automatic.waitForExistence(timeout: 5))
        XCTAssertEqual(automatic.value as? String, "1")
        captureHierarchy("Memory controls before native switch interaction", app)
        tapSwitch(automatic)
        expect { automatic.value as? String == "0" }
        tapSwitch(enabled)
        expect { enabled.value as? String == "0" }
        XCTAssertFalse(automatic.isEnabled)
        XCTAssertTrue(app.buttons["memory-item-fixture-memory"].exists)
        tapSwitch(enabled)
        expect { enabled.value as? String == "1" }
        XCTAssertEqual(automatic.value as? String, "0", "Turning Memory on must preserve the automatic choice")
        capture("Memory dark controls", app)
        app.swipeUp()
        let clear = app.buttons["memory-clear"]
        for _ in 0..<4 where !clear.isHittable { app.swipeUp() }
        XCTAssertTrue(clear.isHittable); clear.tap()
        let confirmation = app.buttons["确认清空全部记忆"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        capture("Memory clear confirmation", app)
        confirmation.tap()
        XCTAssertTrue(app.staticTexts["memory-empty"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testLargestTextLightAndLandscapeMemoryPages() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launchEnvironment["ZEN_MEMORY_UI_TEST"] = "seed"
        app.launchEnvironment["ZEN_MEMORY_UI_APPEARANCE"] = "light"
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        app.launch()
        XCTAssertTrue(app.textViews["conversation-composer-input"].waitForExistence(timeout: 15))
        guard openMemory(app) else { return }
        XCTAssertTrue(app.switches["memory-enabled"].waitForExistence(timeout: 5))
        capture("Memory largest light portrait controls", app)
        let row = app.buttons["memory-item-fixture-memory"]
        for _ in 0..<8 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.isHittable); row.tap()
        XCTAssertTrue(app.textViews["memory-content"].waitForExistence(timeout: 5))
        capture("Memory largest light portrait editor", app)
        app.swipeUp()
        capture("Memory largest light portrait provenance", app)
        XCUIDevice.shared.orientation = .landscapeLeft
        // Existing Workspace policy closes overlays on window-size changes.
        // Re-enter through the real route to inspect the landscape page itself.
        XCTAssertTrue(app.textViews["conversation-composer-input"].waitForExistence(timeout: 5))
        guard openMemory(app) else { return }
        let landscapeRow = app.buttons["memory-item-fixture-memory"]
        for _ in 0..<10 where !landscapeRow.isHittable { app.swipeUp() }
        XCTAssertTrue(landscapeRow.isHittable); landscapeRow.tap()
        let landscapeEditor = app.textViews["memory-content"]
        XCTAssertTrue(landscapeEditor.waitForExistence(timeout: 5))
        XCTAssertEqual(landscapeEditor.value as? String, "I work on Windows")
        captureHierarchy("Memory largest landscape hierarchy", app)
        capture("Memory largest light landscape", app)
    }

    @MainActor
    private func capture(_ name: String, _ app: XCUIApplication) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }

    @MainActor
    private func captureHierarchy(_ name: String, _ app: XCUIApplication) {
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name; tree.lifetime = .keepAlways; add(tree)
    }

    @MainActor
    private func tapSwitch(_ element: XCUIElement) {
        // SwiftUI exposes the label and trailing native thumb as one AX Switch.
        // Its row midpoint is the label; exercise the rendered thumb itself.
        XCTAssertTrue(element.isHittable)
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }

    @MainActor
    private func expect(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let pending = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [pending], timeout: 5), .completed, file: file, line: line)
    }

    @MainActor
    func testEditAndConfirmedErasureUseTheFormalMemoryPage() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launchEnvironment["ZEN_MEMORY_UI_TEST"] = "seed"
        app.launch()
        XCTAssertTrue(app.textViews["conversation-composer-input"].waitForExistence(timeout: 15))
        guard openMemory(app) else { return }
        let row = app.buttons["memory-item-fixture-memory"]
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        let text = app.textViews["memory-content"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        XCTAssertEqual(text.value as? String, "I work on Windows")
        text.tap(); text.typeText(" and Swift")
        app.buttons["memory-save"].tap()
        XCTAssertTrue(app.staticTexts["memory-save-status"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["来源会话已删除"].exists)
        app.swipeUp()
        let deletion = app.buttons["memory-delete"]
        for _ in 0..<4 where !deletion.isHittable { app.swipeUp() }
        XCTAssertTrue(deletion.isHittable); deletion.tap()
        let confirmation = app.buttons["确认删除记忆"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        // Regular-width native confirmations omit Cancel and dismiss outside.
        if app.buttons["取消"].exists { app.buttons["取消"].tap() }
        else {
            // The native popup covers the navigation title. Its actual AX
            // dismiss region is the safe outside target, verified in the recording.
            let outside = app.otherElements["PopoverDismissRegion"]
            XCTAssertTrue(outside.waitForExistence(timeout: 5)); outside.tap()
        }
        guard confirmation.wait(for: \.exists, toEqual: false, timeout: 5) else { XCTFail("Native confirmation did not cancel"); return }
        XCTAssertTrue(app.navigationBars["记忆详情"].exists)
        deletion.tap()
        app.buttons["确认删除记忆"].tap()
        XCTAssertTrue(app.staticTexts["memory-empty"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Memory empty after confirmed erasure"; screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testFormalMemoryEntryPreservesConversationDraft() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launch()
        let editor = app.textViews["conversation-composer-input"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        editor.tap(); editor.typeText("memory management draft")
        app.openWorkspaceSidebar()
        let settings = app.buttons["sidebar-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5)); settings.tap()
        let agent = app.buttons["settings-agent"]
        XCTAssertTrue(agent.waitForExistence(timeout: 5)); agent.tap()
        let memory = app.buttons["settings-memory"]
        guard memory.waitForExistence(timeout: 5) else { XCTFail("Formal Memory destination is missing"); return }
        memory.tap()
        XCTAssertTrue(app.switches["memory-enabled"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["memory-empty"].exists)
        app.buttons["settings-close"].tap()
        XCTAssertEqual(editor.value as? String, "memory management draft")
    }

    @MainActor
    private func openMemory(_ app: XCUIApplication) -> Bool {
        app.openWorkspaceSidebar()
        let settings = app.buttons["sidebar-settings"]
        guard settings.waitForExistence(timeout: 5) else { XCTFail("Settings missing"); return false }
        settings.tap()
        let agent = app.buttons["settings-agent"]
        for _ in 0..<5 where !agent.isHittable { app.swipeUp() }
        guard agent.waitForExistence(timeout: 5) else { XCTFail("Agent missing"); return false }
        agent.tap()
        let memory = app.buttons["settings-memory"]
        guard memory.waitForExistence(timeout: 5) else { XCTFail("Memory missing"); return false }
        memory.tap(); return true
    }
}

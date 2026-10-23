import XCTest

final class MemorySettingsUITests: XCTestCase {
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

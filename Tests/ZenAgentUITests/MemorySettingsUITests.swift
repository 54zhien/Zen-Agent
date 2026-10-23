import XCTest

final class MemorySettingsUITests: XCTestCase {
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
}

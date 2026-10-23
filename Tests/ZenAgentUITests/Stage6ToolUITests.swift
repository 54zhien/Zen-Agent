import XCTest

final class Stage6ToolUITests: XCTestCase {
    @MainActor
    func testAgentSettingsShowsCallableToolsAndActualEmptyAvailability() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launch()
        let editor = app.textViews["conversation-composer-input"]
        guard editor.waitForExistence(timeout: 15) else { XCTFail("Conversation must load"); return }
        let originalDraft = editor.value as? String
        app.openWorkspaceSidebar()
        let settings = app.buttons["sidebar-settings"]
        guard settings.waitForExistence(timeout: 5) else { XCTFail("Formal Settings entry must exist"); return }
        settings.tap()
        let agent = app.buttons["settings-agent"]
        guard agent.waitForExistence(timeout: 5) else { XCTFail("Formal Agent Settings must exist"); return }
        agent.tap()
        let tools = app.buttons["settings-tools"]
        guard tools.waitForExistence(timeout: 5) else { XCTFail("Agent must expose the authorized callable tools destination"); return }
        tools.tap()
        XCTAssertTrue(app.staticTexts["settings-tools-unavailable"].waitForExistence(timeout: 5),
            "An empty injected registry must show actual unavailability")
        app.buttons["settings-close"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, originalDraft)
    }
}

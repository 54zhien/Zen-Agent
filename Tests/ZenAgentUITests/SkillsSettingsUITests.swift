import XCTest

final class SkillsSettingsUITests: XCTestCase {
    @MainActor
    func testFormalSkillsEntryUsesTheApprovedManagementPage() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launch()
        XCTAssertTrue(app.textViews["conversation-composer-input"].waitForExistence(timeout: 15))
        guard openExtensionSettings(app, id: "settings-skills", title: "Skills") else { return }
        XCTAssertTrue(app.buttons["skill-item-zen.calculate"].waitForExistence(timeout: 5))
        captureExtension("Skills native list", app)
    }
}

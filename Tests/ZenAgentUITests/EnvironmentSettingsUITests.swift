import XCTest

final class EnvironmentSettingsUITests: XCTestCase {
    @MainActor
    func testFormalEnvironmentEntryUsesTheApprovedManagementPage() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launch()
        XCTAssertTrue(app.textViews["conversation-composer-input"].waitForExistence(timeout: 15))
        guard openExtensionSettings(app, id: "settings-environment", title: "环境变量") else { return }
        XCTAssertTrue(app.buttons["environment-add"].waitForExistence(timeout: 5))
        captureExtension("Environment native empty list", app)
    }
}

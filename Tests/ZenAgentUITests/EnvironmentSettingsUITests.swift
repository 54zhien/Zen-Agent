import XCTest

final class EnvironmentSettingsUITests: XCTestCase {
    @MainActor
    func testSecretIsMaskedAfterReopenAndDeletionRequiresConfirmation() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launchEnvironment["ZEN_MEMORY_UI_TEST"] = "seed"
        app.launchEnvironment["ZEN_MEMORY_UI_APPEARANCE"] = "dark"
        app.launch()
        guard openExtensionSettings(app, id: "settings-environment", title: "环境变量") else { return }
        app.buttons["environment-add"].tap()
        let key = app.textFields["environment-key"]
        XCTAssertTrue(key.waitForExistence(timeout: 5)); key.tap(); key.typeText("UI_AUTH")
        let kind = app.buttons["environment-kind"]
        guard tapExtensionLabel(kind, in: app) else { return }
        app.buttons["密钥"].tap()
        let secret = app.secureTextFields["environment-secret-value"]
        XCTAssertTrue(secret.waitForExistence(timeout: 5)); secret.tap(); secret.typeText("fixture-ui-secret")
        captureExtension("Environment secure input masked", app)
        app.buttons["environment-save"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "environment-variable-")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["fixture-ui-secret"].exists)
        guard tapExtensionLabel(row.staticTexts["UI_AUTH"], in: app) else { return }
        let reopened = app.secureTextFields["environment-secret-value"]
        XCTAssertTrue(reopened.waitForExistence(timeout: 5))
        XCTAssertNotEqual(reopened.value as? String, "fixture-ui-secret")
        captureExtension("Environment existing Secret has no reveal path", app)
        guard tapExtensionLabel(app.buttons["environment-delete"], in: app) else { return }
        let confirm = app.buttons["确认删除变量"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        captureExtension("Environment dependency deletion confirmation", app)
        confirm.tap()
        XCTAssertTrue(app.staticTexts["environment-empty"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testLargestTypeEnvironmentScopesInLandscape() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        app.launch()
        guard openExtensionSettings(app, id: "settings-environment", title: "环境变量") else { return }
        app.buttons["environment-add"].tap()
        XCTAssertTrue(app.textFields["environment-key"].waitForExistence(timeout: 5))
        captureExtension("Environment largest landscape identity", app)
        let kind = app.buttons["environment-kind"]
        guard tapExtensionLabel(kind, in: app) else { return }
        captureExtension("Environment largest landscape kind choices", app)
    }

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

import XCTest

final class SkillsSettingsUITests: XCTestCase {
    @MainActor
    func testComposerPluginEntryProvidesAutomaticSkillSelection() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launch()
        let plus = app.buttons["conversation-composer-plus"]
        XCTAssertTrue(plus.waitForExistence(timeout: 15)); plus.tap()
        let plugins = app.buttons["插件"]
        XCTAssertTrue(plugins.waitForExistence(timeout: 5))
        captureExtension("Composer plugin entry", app)
        XCTAssertTrue(plugins.isEnabled)
        guard plugins.isEnabled else { return }
        plugins.tap()
        let automatic = app.buttons["自动选择"]
        XCTAssertTrue(automatic.waitForExistence(timeout: 5)); automatic.tap()
        XCTAssertTrue(waitForExtension { plus.value as? String == "自动选择 Skill" })
    }

    @MainActor
    func testExplicitUserSaveAndComposerSelectionKeepTheNativeMenu() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launch()
        guard openExtensionSettings(app, id: "settings-skills", title: "Skills") else { return }
        let enabled = app.switches["skill-enabled-zen.calculate"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 5))
        XCTAssertEqual(enabled.value as? String, "0")
        enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(waitForExtension { enabled.value as? String == "1" })
        app.buttons["skill-add"].tap()
        let name = app.textFields["skill-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("UI Workflow")
        let instructions = app.textViews["skill-instructions"]
        guard tapExtensionLabel(instructions, in: app) else { return }
        instructions.typeText("UI_WORKFLOW_INSTRUCTION")
        captureExtension("Skill unsaved native editor", app)
        app.buttons["skill-save"].tap()
        XCTAssertTrue(app.navigationBars["Skills"].waitForExistence(timeout: 5))
        let userRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "skill-item-user-")).firstMatch
        XCTAssertTrue(userRow.waitForExistence(timeout: 5))
        let userSwitch = app.switches[userRow.identifier.replacingOccurrences(of: "skill-item-", with: "skill-enabled-")]
        guard tapExtensionLabel(userSwitch, in: app, tap: false) else { return }
        userSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(waitForExtension { userSwitch.value as? String == "1" })
        captureExtension("Skills saved native list", app)
        app.buttons["settings-close"].tap()
        let plus = app.buttons["conversation-composer-plus"]
        XCTAssertTrue(plus.waitForExistence(timeout: 5)); plus.tap()
        let plugins = app.buttons["插件"]
        XCTAssertTrue(plugins.waitForExistence(timeout: 5)); XCTAssertTrue(plugins.isEnabled); plugins.tap()
        let workflow = app.buttons["UI Workflow"]
        XCTAssertTrue(workflow.waitForExistence(timeout: 5)); workflow.tap()
        XCTAssertTrue(waitForExtension { plus.value as? String == "已选择 1 个 Skill" })
        captureExtension("Composer selected Skill retains native menu", app)
    }

    @MainActor
    func testLargestTypeSkillDetailsPortraitAndLandscape() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        app.launch()
        guard openExtensionSettings(app, id: "settings-skills", title: "Skills") else { return }
        let row = app.buttons["skill-item-zen.calculate"]
        guard tapExtensionLabel(row.staticTexts["计算核验"], in: app) else { return }
        XCTAssertTrue(app.staticTexts["skill-instructions-readonly"].waitForExistence(timeout: 5))
        captureExtension("Skill largest portrait detail", app)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.textViews["conversation-composer-input"].waitForExistence(timeout: 5))
        guard openExtensionSettings(app, id: "settings-skills", title: "Skills") else { return }
        guard tapExtensionLabel(app.buttons["skill-item-zen.calculate"].staticTexts["计算核验"], in: app) else { return }
        captureExtension("Skill largest landscape detail", app)
    }

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

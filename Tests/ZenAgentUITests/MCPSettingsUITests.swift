import XCTest

final class MCPSettingsUITests: XCTestCase {
    @MainActor
    func testServerConfigurationUsesExistingCredentialReferenceAndSharedToolPolicy() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launch()
        XCTAssertTrue(app.textViews["conversation-composer-input"].waitForExistence(timeout: 15))
        guard openExtensionSettings(app, id: "settings-mcp", title: "MCP") else { return }
        XCTAssertTrue(app.buttons["mcp-add"].waitForExistence(timeout: 5))
        app.buttons["mcp-add"].tap()

        let name = app.textFields["mcp-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("UI MCP Server")
        let endpoint = app.textFields["mcp-endpoint"]
        endpoint.tap()
        endpoint.typeText("https://mcp.example.test/mcp")
        XCTAssertTrue(app.descendants(matching: .any)["mcp-credential-reference"].exists)
        XCTAssertTrue(app.buttons["mcp-save"].exists)
        XCTAssertTrue(app.staticTexts["mcp-credential-note"].exists)
        app.buttons["mcp-save"].tap()

        let server = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "mcp-server-")
        ).firstMatch
        XCTAssertTrue(server.waitForExistence(timeout: 5))
        XCTAssertTrue(server.staticTexts["UI MCP Server"].exists)
        let enabled = app.switches.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "mcp-enabled-")
        ).firstMatch
        XCTAssertTrue(enabled.waitForExistence(timeout: 5))
        XCTAssertEqual(enabled.value as? String, "0")
        enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(waitForExtension { enabled.value as? String == "1" })

        server.tap()
        XCTAssertTrue(app.navigationBars["MCP 服务"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["mcp-connect"].waitForExistence(timeout: 5))
        let connectionState = app.staticTexts["mcp-connection-state"]
        XCTAssertTrue(connectionState.waitForExistence(timeout: 5))
        XCTAssertEqual(connectionState.label, "未连接")
        app.swipeUp()
        let toolPolicy = app.buttons["mcp-tool-policy"]
        XCTAssertTrue(toolPolicy.waitForExistence(timeout: 5))
        toolPolicy.tap()
        XCTAssertTrue(app.navigationBars["可调用工具"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let delete = app.buttons["mcp-delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let confirm = app.buttons["mcp-delete-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["mcp-empty"].waitForExistence(timeout: 5))
    }
}

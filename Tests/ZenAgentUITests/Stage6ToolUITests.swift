import XCTest

final class Stage6ToolUITests: XCTestCase {
    @MainActor
    func testFileDisclosureConversationGrantAndSettingsRevocation() {
        let app = launchTool("files")
        guard sendAndWaitForCard(app) else { return }
        XCTAssertTrue(app.staticTexts["tool-approval-target"].label.contains("版本"))
        XCTAssertTrue(app.staticTexts["tool-approval-impact"].label.contains("https://stage6-provider.invalid/chat/completions"))
        snapshot(app, "Frozen file and Provider disclosure")
        guard tapDecision("允许本会话", app: app) else { return }
        XCTAssertTrue(app.staticTexts["stage6-continued"].waitForExistence(timeout: 15))
        XCTAssertTrue(waitObservation(app, contains: "activeGrants=1"))
        guard openTools(app) else { return }
        let revoke = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tool-revoke-")).firstMatch
        for _ in 0..<6 where !revoke.isHittable { app.swipeUp() }
        guard revoke.waitForExistence(timeout: 5), revoke.isHittable else { XCTFail("Original grant must be revocable"); return }
        revoke.tap()
        XCTAssertTrue(app.staticTexts["用户已撤销此授权。"].waitForExistence(timeout: 5))
        snapshot(app, "Original scoped grant revoked")
        app.buttons["settings-close"].tap()
        XCTAssertTrue(waitObservation(app, contains: "activeGrants=0"))
    }

    @MainActor
    func testSettingsDenyRejectsTheOldFileCardWithoutExecuting() {
        let app = launchTool("files")
        guard sendAndWaitForCard(app), openTools(app) else { return }
        let picker = app.buttons["tool-policy-files-read"]
        guard picker.waitForExistence(timeout: 5) else { XCTFail("File read policy must be editable"); return }
        picker.tap()
        let deny = app.buttons["禁止"]
        guard deny.waitForExistence(timeout: 5) else { XCTFail("Deny policy choice must exist"); return }
        deny.tap()
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "禁止", "禁止"),
            object: picker)], timeout: 10) == .completed)
        // Wait for the real model write to drain before closing this presentation.
        XCTAssertTrue(waitEnabled(picker))
        app.buttons["settings-close"].tap()
        guard tapDecision("批准本次", app: app) else { return }
        XCTAssertTrue(waitObservation(app, contains: "state=rejected"))
        XCTAssertTrue(waitObservation(app, contains: "activeGrants=0"))
        XCTAssertFalse(app.staticTexts["stage6-managed-document"].exists)
        snapshot(app, "Old approval rejected by current policy")
    }

    @MainActor
    func testSystemConsentRequestsOnceWithoutIssuingToolGrant() {
        let app = launchTool("system")
        guard sendAndWaitForCard(app) else { return }
        XCTAssertFalse(app.buttons["批准本次"].exists)
        XCTAssertFalse(app.buttons["允许本会话"].exists)
        XCTAssertTrue(waitObservation(app, contains: "requests=0;executions=0;activeGrants=0"))
        snapshot(app, "Independent system consent")
        guard tapDecision("请求系统权限", app: app) else { return }
        XCTAssertTrue(app.staticTexts["stage6-continued"].waitForExistence(timeout: 15))
        XCTAssertTrue(waitObservation(app, contains: "requests=1;executions=1;activeGrants=0"))
    }

    @MainActor
    func testDecliningSystemConsentNeverRequestsOrExecutes() {
        let app = launchTool("system")
        guard sendAndWaitForCard(app), tapDecision("暂不请求", app: app) else { return }
        XCTAssertTrue(waitObservation(app, contains: "state=rejected"))
        XCTAssertTrue(waitObservation(app, contains: "requests=0;executions=0;activeGrants=0"))
        XCTAssertTrue(app.staticTexts["stage6-continued"].waitForExistence(timeout: 15))
    }

    @MainActor
    private func launchTool(_ mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_STAGE6_TOOL_UI_TEST"] = mode
        app.launch()
        return app
    }

    @MainActor
    private func sendAndWaitForCard(_ app: XCUIApplication) -> Bool {
        let editor = app.textViews["conversation-composer-input"]
        guard editor.waitForExistence(timeout: 15) else { XCTFail("Configured conversation must open"); return false }
        editor.tap(); editor.typeText("Stage 6 tool request")
        let send = app.buttons["conversation-composer-send"]
        guard waitEnabled(send) else { XCTFail("Production Composer bridge must be ready"); return false }
        send.tap()
        guard app.otherElements["tool-approval-card"].waitForExistence(timeout: 15) else {
            XCTFail("Real Runtime must publish an approval card"); return false
        }
        return true
    }

    @MainActor
    private func tapDecision(_ title: String, app: XCUIApplication) -> Bool {
        let button = app.buttons[title]
        guard button.waitForExistence(timeout: 5) else { XCTFail("Missing decision: \(title)"); return false }
        let card = app.otherElements["tool-approval-card"]
        for _ in 0..<8 where !button.isHittable { card.swipeUp() }
        guard button.isHittable else { XCTFail("Decision must be reachable: \(title)"); return false }
        button.tap()
        return true
    }

    @MainActor
    private func openTools(_ app: XCUIApplication) -> Bool {
        app.openWorkspaceSidebar()
        let settings = app.buttons["sidebar-settings"]
        guard settings.waitForExistence(timeout: 5) else { XCTFail("Settings entry missing"); return false }
        settings.tap()
        let agent = app.buttons["settings-agent"]
        guard agent.waitForExistence(timeout: 5) else { XCTFail("Agent entry missing"); return false }
        agent.tap()
        let tools = app.buttons["settings-tools"]
        guard tools.waitForExistence(timeout: 5) else { XCTFail("Tool Settings missing"); return false }
        tools.tap()
        return true
    }

    @MainActor
    private func waitObservation(_ app: XCUIApplication, contains text: String) -> Bool {
        let observation = app.staticTexts["stage6-tool-observation"]
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text),
            object: observation)], timeout: 10) == .completed
    }

    @MainActor
    private func waitEnabled(_ element: XCUIElement) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"),
            object: element)], timeout: 10) == .completed
    }

    @MainActor
    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }

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

import XCTest

final class ComposerMotionUITests: XCTestCase {
    @MainActor
    func testThinkingDetentsAdaptWhenSwitchingThreeAndFourLevelModels() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_COMPOSER_GEOMETRY_TEST"] = "1"
        app.launchEnvironment["ZEN_COMPOSER_THINKING_LEVELS_TEST"] = "1"
        app.launch()
        let plus = app.buttons["conversation-composer-plus"]
        XCTAssertTrue(plus.waitForExistence(timeout: 15))
        plus.tap()
        let entry = app.buttons["思考"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        let detail = app.descendants(matching: .any)["composer-detail-thinking"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        let control = app.descendants(matching: .any)["thinking-curved-control"]
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        XCTAssertEqual(control.value as? String, "高")
        let defaultButton = app.buttons["thinking-level-default"]
        XCTAssertTrue(defaultButton.isSelected)
        guard let threeLevelDetents = thinkingDetents(in: app, control: control, expectedCount: 3) else { return }
        for (index, level) in ["低", "高", "Max"].enumerated() {
            threeLevelDetents[index].tap()
            XCTAssertTrue(waitForValue(level, in: control), "Expected the three-level rail to select \(level)")
            XCTAssertFalse(defaultButton.isSelected)
        }

        app.buttons["关闭，返回一级菜单"].tap()
        XCTAssertTrue(detail.waitForNonExistence(timeout: 5))
        let modelEntry = app.buttons["模型"]
        XCTAssertTrue(modelEntry.waitForExistence(timeout: 5))
        modelEntry.tap()
        let modelDetail = app.descendants(matching: .any)["composer-detail-models"]
        XCTAssertTrue(modelDetail.waitForExistence(timeout: 5))
        modelOption("UI Test Model With A Longer Name", in: app).tap()
        XCTAssertTrue(modelDetail.waitForNonExistence(timeout: 5))
        XCTAssertTrue(waitForValue("中", in: entry))

        entry.tap()
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue("中", in: control))
        XCTAssertTrue(defaultButton.isSelected)
        guard let fourLevelDetents = thinkingDetents(in: app, control: control, expectedCount: 4) else { return }
        for (index, level) in ["低", "中", "高", "极高"].enumerated() {
            fourLevelDetents[index].tap()
            XCTAssertTrue(waitForValue(level, in: control), "Expected the four-level rail to select \(level)")
        }

        app.buttons["关闭，返回一级菜单"].tap()
        XCTAssertTrue(detail.waitForNonExistence(timeout: 5))
        modelEntry.tap()
        XCTAssertTrue(modelDetail.waitForExistence(timeout: 5))
        modelOption("UI Test Model", in: app).tap()
        XCTAssertTrue(modelDetail.waitForNonExistence(timeout: 5))
        XCTAssertTrue(waitForValue("高", in: entry))
        entry.tap()
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue("高", in: control))
        XCTAssertTrue(defaultButton.isSelected)
        guard let returnedToThreeLevelDetents = thinkingDetents(in: app, control: control, expectedCount: 3) else { return }
        XCTAssertEqual(returnedToThreeLevelDetents.count, 3)
    }

    @MainActor
    func testThinkingDetailOpensAndKeepsSelectedLevel() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_COMPOSER_GEOMETRY_TEST"] = "1"
        app.launch()
        let plus = app.buttons["conversation-composer-plus"]
        XCTAssertTrue(plus.waitForExistence(timeout: 15))
        plus.tap()
        let entry = app.buttons["思考"]
        guard entry.waitForExistence(timeout: 5), entry.isEnabled else {
            XCTFail("Thinking must be enabled and open its detail sheet")
            return
        }
        entry.tap()
        let detail = app.descendants(matching: .any)["composer-detail-thinking"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        let control = app.descendants(matching: .any)["thinking-curved-control"]
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        XCTAssertEqual(control.value as? String, "高")
        let defaultButton = app.buttons["thinking-level-default"]
        XCTAssertTrue(defaultButton.isSelected)
        guard let sixLevelDetents = thinkingDetents(in: app, control: control, expectedCount: 6) else { return }
        for (index, level) in ["低", "中", "高", "极高", "Max", "Ultra"].enumerated() {
            sixLevelDetents[index].tap()
            XCTAssertTrue(waitForValue(level, in: control), "Expected the six-level rail to select \(level)")
        }
        XCTAssertFalse(defaultButton.isSelected)

        app.buttons["关闭，返回一级菜单"].tap()
        XCTAssertTrue(detail.waitForNonExistence(timeout: 5))
        XCTAssertTrue(waitForValue("Ultra", in: entry))
        entry.tap()
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue("Ultra", in: control))
        XCTAssertFalse(defaultButton.isSelected)
        defaultButton.tap()
        XCTAssertTrue(waitForValue("高", in: control))
        XCTAssertTrue(defaultButton.isSelected)
        app.buttons["关闭，返回一级菜单"].tap()
        XCTAssertTrue(detail.waitForNonExistence(timeout: 5))
        entry.tap()
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue("高", in: control))
        XCTAssertTrue(defaultButton.isSelected)
    }

    @MainActor
    func testModelMenuOpensAndSwitchesModels() throws {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_COMPOSER_GEOMETRY_TEST"] = "1"
        app.launch()
        let plus = app.buttons["conversation-composer-plus"]
        XCTAssertTrue(plus.waitForExistence(timeout: 15))
        let title = app.buttons["模型"]
        let panel = app.descendants(matching: .any)["composer-action-menu"]
        let modelDetail = app.descendants(matching: .any)["composer-detail-models"]
        let first = modelOption("UI Test Model", in: app)
        let second = modelOption("UI Test Model With A Longer Name", in: app)

        plus.tap()
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let root = XCTAttachment(screenshot: app.screenshot())
        root.name = "Shared glass menu before model expansion"
        root.lifetime = .keepAlways
        add(root)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.3)).tap()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
        XCTAssertTrue(plus.isHittable)
        let input = app.textViews["conversation-composer-input"]
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        // A fresh Simulator introduces slide-to-type after the first key;
        // finish that system onboarding before it can swallow the remaining draft.
        input.typeText("m")
        let keyboardIntroduction = app.buttons["Continue"]
        if keyboardIntroduction.waitForExistence(timeout: 2) { keyboardIntroduction.tap() }
        input.typeText("enu draft")
        XCTAssertEqual(input.value as? String, "menu draft")
        // AX Keyboard may omit the accessory/chrome region. The native guide
        // records the complete occupied frame used for the actual handoff.
        let probe = app.otherElements["composer-geometry-probe"]
        let guideField = (probe.value as? String ?? "").split(separator: ";")
            .first { $0.hasPrefix("guide=") }
        let keyboardTop = try XCTUnwrap(guideField.flatMap { Double($0.dropFirst(6)) })
        let keyboardHeight = app.frame.maxY - CGFloat(keyboardTop)
        let inputBottom = input.frame.maxY
        plus.tap()
        let openedPanel = panel.waitForExistence(timeout: 5)
        print("KEYBOARD_MENU_HANDOFF \(app.otherElements["composer-geometry-probe"].value ?? "missing probe")")
        XCTAssertTrue(openedPanel)
        // A custom inputView may remain in the system Keyboard AX container.
        let sheet = app.otherElements["composer-keyboard-sheet"]
        guard sheet.waitForExistence(timeout: 5) else {
            XCTFail("The keyboard must be replaced by the bottom sheet")
            return
        }
        XCTAssertEqual(sheet.frame.height, keyboardHeight, accuracy: 2)
        XCTAssertEqual(input.frame.maxY, inputBottom, accuracy: 2)
        XCTAssertEqual(plus.label, "关闭菜单")
        let labels = ["模型", "思考", "插件", "图片", "文件"].map {
            app.buttons.matching(NSPredicate(format: "label == %@", $0)).firstMatch
        }
        for row in labels { XCTAssertTrue(row.exists) }
        for index in 1..<labels.count {
            XCTAssertGreaterThan(labels[index].frame.midY, labels[index - 1].frame.midY)
        }
        let replacement = XCTAttachment(screenshot: app.screenshot())
        replacement.name = "Keyboard replaced by five-row liquid sheet"
        replacement.lifetime = .keepAlways
        add(replacement)
        app.buttons["思考"].tap()
        let thinkingDetail = app.descendants(matching: .any)["composer-detail-thinking"]
        XCTAssertTrue(thinkingDetail.waitForExistence(timeout: 5))
        let thinkingControl = app.descendants(matching: .any)["thinking-curved-control"]
        XCTAssertTrue(thinkingControl.waitForExistence(timeout: 5))
        XCTAssertEqual(thinkingControl.value as? String, "高")
        guard let initialKeyboardDetents = thinkingDetents(in: app, control: thinkingControl, expectedCount: 6) else { return }
        XCTAssertEqual(initialKeyboardDetents.count, 6)
        XCTAssertEqual(input.frame.maxY, inputBottom, accuracy: 2)
        app.buttons["关闭，返回一级菜单"].tap()
        XCTAssertTrue(thinkingDetail.waitForNonExistence(timeout: 5))
        XCTAssertTrue(sheet.exists)
        app.buttons["思考"].tap()
        XCTAssertTrue(thinkingDetail.waitForExistence(timeout: 5))
        guard let keyboardDetents = thinkingDetents(in: app, control: thinkingControl, expectedCount: 6) else { return }
        XCTAssertEqual(keyboardDetents.count, 6)
        keyboardDetents[1].tap()
        XCTAssertTrue(waitForValue("中", in: thinkingControl))
        app.buttons["关闭，返回一级菜单"].tap()
        XCTAssertTrue(thinkingDetail.waitForNonExistence(timeout: 5))
        XCTAssertTrue(sheet.exists)
        XCTAssertEqual(app.buttons["思考"].value as? String, "中")
        plus.tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        XCTAssertEqual(input.value as? String, "menu draft")
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        plus.tap()
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        // Tapping the retained editor replaces the sheet with the real keyboard.
        input.tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        XCTAssertEqual(input.value as? String, "menu draft")
        plus.tap()
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        title.tap()
        XCTAssertTrue(modelDetail.waitForExistence(timeout: 5))
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(second.exists)
        XCTAssertTrue(first.isSelected)
        XCTAssertFalse(second.isSelected)
        let initial = XCTAttachment(screenshot: app.screenshot())
        initial.name = "Model menu before selection"
        initial.lifetime = .keepAlways
        add(initial)

        app.buttons["关闭，返回一级菜单"].tap()
        XCTAssertTrue(modelDetail.waitForNonExistence(timeout: 5))
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertTrue(sheet.exists)
        title.tap()
        XCTAssertTrue(modelDetail.waitForExistence(timeout: 5))
        second.tap()
        XCTAssertTrue(second.waitForNonExistence(timeout: 5))
        XCTAssertTrue(modelDetail.waitForNonExistence(timeout: 5))
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertTrue(sheet.exists)
        XCTAssertTrue(plus.isHittable)
        XCTAssertEqual(input.value as? String, "menu draft")

        title.tap()
        XCTAssertTrue(modelDetail.waitForExistence(timeout: 5))
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        XCTAssertTrue(second.isSelected)
        XCTAssertFalse(first.isSelected)
        let changed = XCTAttachment(screenshot: app.screenshot())
        changed.name = "Model menu after selection"
        changed.lifetime = .keepAlways
        add(changed)
        app.buttons["关闭，返回一级菜单"].tap()
        XCTAssertTrue(modelDetail.waitForNonExistence(timeout: 5))

        plus.tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        XCTAssertEqual(input.value as? String, "menu draft")
        plus.tap()
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        XCTAssertTrue(modelDetail.waitForExistence(timeout: 5))
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        XCTAssertTrue(second.isSelected)
        XCTAssertFalse(first.isSelected)
        app.buttons["关闭，返回一级菜单"].tap()
        XCTAssertTrue(modelDetail.waitForNonExistence(timeout: 5))
        plus.tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testKeyboardAndComposerStayInteractiveAcrossQuickFocusChanges() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_COMPOSER_GEOMETRY_TEST"] = "1"
        app.launch()
        let input = app.textViews["conversation-composer-input"]
        let probe = app.otherElements["composer-geometry-probe"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        XCTAssertTrue(probe.waitForExistence(timeout: 15))
        let restingRoot = metric("root", from: probe)

        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(waitForKeyboardGap(probe, expected: 12))
        XCTAssertLessThanOrEqual(abs(metric("root", from: probe) - restingRoot), 1)
        let prompt = app.staticTexts["这是一条用于验证消息点击不会收起输入框的较长测试消息，点按后应当展开完整内容，并继续保持键盘和输入框的焦点。"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        let collapsedHeight = prompt.frame.height
        prompt.tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertGreaterThan(prompt.frame.height, collapsedHeight)
        let background = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.38))
        background.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 8))

        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        input.typeText("你好")
        // The native recording can already show both characters while the first
        // accessibility snapshot still exposes the preceding text revision.
        let receivedText = waitForText("你好", in: input)
        let observedAfterTyping = input.value as? String
        guard receivedText else {
            XCTFail("Expected typed Chinese input; observed \(String(describing: observedAfterTyping))")
            return
        }
        let send = app.buttons["conversation-composer-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()
        XCTAssertTrue(waitForEmptyInput(input))
        input.typeText("第二条")
        XCTAssertTrue(waitForText("第二条", in: input))
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()
        XCTAssertTrue(waitForEmptyInput(input))
        background.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 8))
    }

    @MainActor
    private func thinkingDetents(in app: XCUIApplication, control: XCUIElement,
                                 expectedCount: Int) -> [XCUIElement]? {
        let bounds = control.frame.insetBy(dx: -1, dy: -1)
        let detents = app.buttons.allElementsBoundByIndex
            .filter { button in
                guard button.label.isEmpty else { return false }
                return bounds.contains(CGPoint(x: button.frame.midX, y: button.frame.midY))
            }
            .sorted { $0.frame.midX < $1.frame.midX }
        guard detents.count == expectedCount else {
            XCTFail("Expected \(expectedCount) visible thinking detents inside the curved control; found \(detents.count)")
            return nil
        }
        return detents
    }

    @MainActor
    private func modelOption(_ name: String, in app: XCUIApplication) -> XCUIElement {
        // Native AX combines the model name and its supported thinking levels
        // into the row's label; the comma keeps similarly prefixed names distinct.
        app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@",
            name, name + ", ")).firstMatch
    }

    @MainActor
    private func waitForValue(_ expected: String, in element: XCUIElement) -> Bool {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (element.value as? String) == expected
        }, object: nil)
        return XCTWaiter.wait(for: [ready], timeout: 5) == .completed
    }

    @MainActor
    private func waitForText(_ expected: String, in input: XCUIElement) -> Bool {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (input.value as? String) == expected
        }, object: nil)
        return XCTWaiter.wait(for: [ready], timeout: 5) == .completed
    }

    @MainActor
    private func waitForEmptyInput(_ input: XCUIElement) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if (input.value as? String ?? "").isEmpty { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    @MainActor
    private func waitForKeyboardGap(_ probe: XCUIElement, expected: Double) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let gap = metric("guide", from: probe) - metric("surface", from: probe)
            if abs(gap - expected) <= 1 { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    @MainActor
    private func metric(_ name: String, from probe: XCUIElement) -> Double {
        let components = (probe.value as? String ?? "").split(separator: ";")
        guard let entry = components.first(where: { $0.hasPrefix("\(name)=") }) else {
            return .nan
        }
        return Double(String(entry.dropFirst(name.count + 1))) ?? .nan
    }
}

import XCTest

final class ComposerMotionUITests: XCTestCase {
    @MainActor
    func testModelMenuOpensAndSwitchesModels() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_COMPOSER_GEOMETRY_TEST"] = "1"
        app.launch()
        let plus = app.buttons["conversation-composer-plus"]
        XCTAssertTrue(plus.waitForExistence(timeout: 15))
        let title = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "模型")).firstMatch
        let panel = app.descendants(matching: .any)["composer-action-menu"]
        let picker = app.descendants(matching: .any)["composer-model-picker"]
        let first = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "UI Test Model")).firstMatch
        let second = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "UI Test Model With A Longer Name")).firstMatch

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
        let keyboardHeight = app.keyboards.firstMatch.frame.height
        let inputBottom = input.frame.maxY
        plus.tap()
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 8))
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
        plus.tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
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
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(sheet.exists)
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(second.exists)
        XCTAssertTrue(first.isSelected)
        XCTAssertFalse(second.isSelected)
        let initial = XCTAttachment(screenshot: app.screenshot())
        initial.name = "Model menu before selection"
        initial.lifetime = .keepAlways
        add(initial)

        title.tap()
        let rootEntry = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "思考")).firstMatch
        XCTAssertTrue(rootEntry.waitForExistence(timeout: 5))
        XCTAssertTrue(panel.exists)
        title.tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 5))

        second.tap()
        XCTAssertTrue(second.waitForNonExistence(timeout: 5))
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
        XCTAssertTrue(plus.isHittable)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertEqual(input.value as? String, "menu draft")
        plus.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        XCTAssertTrue(second.isSelected)
        XCTAssertFalse(first.isSelected)
        let changed = XCTAttachment(screenshot: app.screenshot())
        changed.name = "Model menu after selection"
        changed.lifetime = .keepAlways
        add(changed)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.3)).tap()
        XCTAssertTrue(picker.waitForNonExistence(timeout: 5))
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

import XCTest

final class ComposerMotionUITests: XCTestCase {
    @MainActor
    func testKeyboardMenuReplacesInputAndRestoresDraft() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_COMPOSER_GEOMETRY_TEST"] = "1"
        app.launch()

        let input = app.textViews["conversation-composer-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        let plus = app.buttons["conversation-composer-plus"]
        XCTAssertTrue(plus.waitForExistence(timeout: 5))

        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        input.typeText("d")
        let keyboardIntroduction = app.buttons["Continue"]
        if keyboardIntroduction.waitForExistence(timeout: 2) { keyboardIntroduction.tap() }
        input.typeText("raft")
        XCTAssertEqual(input.value as? String, "draft")

        plus.tap()
        let sheet = app.otherElements["composer-keyboard-sheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["模型"].exists)
        XCTAssertTrue(app.buttons["插件"].exists)
        let image = app.buttons["图片"]
        let file = app.buttons["文件"]
        XCTAssertTrue(image.exists)
        XCTAssertFalse(image.isEnabled)
        XCTAssertTrue(file.exists)
        XCTAssertFalse(file.isEnabled)
        XCTAssertEqual(input.value as? String, "draft")

        plus.tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        XCTAssertEqual(input.value as? String, "draft")
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

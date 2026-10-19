import XCTest

final class AppSpaceBrowseUITests: XCTestCase {
    @MainActor
    func testDistantBrowseAndVerticalDragKeepPreviewUntilExplicitActivation() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launch()
        let editor = app.textViews["conversation-composer-input"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        let readiness = app.descendants(matching: .any)["surface-native-interaction-probe"]
        guard wait({ (readiness.value as? String)?.contains("liftReady=true") == true }) else {
            XCTFail("Native Lift never became ready: \(readiness.value ?? "missing")")
            return
        }
        let start = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        print("BROWSE_LIFT_INPUT editor=\(editor.frame) start=\(start.screenPoint) end=\(start.withOffset(CGVector(dx: 0, dy: -220)).screenPoint) native=\(readiness.value ?? "missing")")
        start.press(forDuration: 0.7, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -220)))
        let card = app.descendants(matching: .any)["workspace-current-card"]
        guard wait({ card.exists && card.label.contains("Workspace conversation 11") }) else {
            XCTFail("Initial native Lift did not enter Card: \(readiness.value ?? "missing")")
            return
        }
        for index in stride(from: 10, through: 4, by: -1) {
            dragHistoryCard(card, towardOlder: true, readiness: readiness)
            guard wait({ card.exists && card.label.contains("Workspace conversation \(index)")
                && (readiness.value as? String)?.contains("phase=idle") == true }) else {
                print("BROWSE_NATIVE \(app.otherElements["surface-native-interaction-probe"].value ?? "missing")")
                XCTFail("Browsing past the initial preview window lost adjacent history \(index); actual Card: \(card.label)")
                return
            }
            XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 0)
        }
        let center = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.press(forDuration: 0.05, thenDragTo: center.withOffset(CGVector(dx: 0, dy: -100)))
        XCTAssertTrue(wait { card.exists && card.label.contains("Workspace conversation 4") })
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 0)
        dragHistoryCard(card, towardOlder: false, readiness: readiness)
        XCTAssertTrue(wait { card.exists && card.label.contains("Workspace conversation 5") })
        card.tap()
        XCTAssertTrue(wait { (app.otherElements["surface-lift-state-probe"].value as? String) == "full" })
        XCTAssertTrue(app.descendants(matching: .any)["conversation-pane-preview-ui-5"].exists)
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 1)
    }

    @MainActor
    func testNativeBrowseCoastsAcrossNeighborsAndOpensNearestHistory() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launch()
        let editor = app.textViews["conversation-composer-input"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        let readiness = app.descendants(matching: .any)["surface-native-interaction-probe"]
        guard wait({ (readiness.value as? String)?.contains("liftReady=true") == true }) else {
            XCTFail("Native Lift never became ready: \(readiness.value ?? "missing")")
            return
        }
        let start = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.7, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -220)))
        let card = app.descendants(matching: .any)["workspace-current-card"]
        XCTAssertTrue(wait { card.exists && card.label.contains("Workspace conversation 11") })
        XCTAssertEqual(card.frame.midX, app.frame.midX, accuracy: 2,
                       "The card nearest the resting detent must be centered on screen")
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 0)

        card.swipeRight(velocity: XCUIGestureVelocity(rawValue: 350))
        // This is the existing native Surface. A horizontal drag must browse,
        // not activate its Return tap handler or remount a hidden editor.
        guard wait({ card.exists && card.label.contains("Workspace conversation 10")
            && (readiness.value as? String)?.contains("phase=idle") == true }) else {
            XCTFail("Horizontal browse did not keep Preview and select the adjacent older history")
            return
        }
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 0)
        card.swipeLeft(velocity: XCUIGestureVelocity(rawValue: 350))
        XCTAssertTrue(wait { card.exists && card.label.contains("Workspace conversation 11")
            && (readiness.value as? String)?.contains("phase=idle") == true })
        card.swipeRight(velocity: XCUIGestureVelocity(rawValue: 5000))
        XCTAssertTrue(wait { card.exists && (readiness.value as? String)?.contains("phase=idle") == true })
        guard let digits = card.label.components(separatedBy: "Workspace conversation ").last?
                .prefix(while: { $0.isNumber }), let selected = Int(digits) else {
            XCTFail("A settled card must retain its selected conversation identity: \(card.label)")
            return
        }
        XCTAssertLessThanOrEqual(selected, 9, "A fast flick must coast beyond the first adjacent card")
        XCTAssertGreaterThanOrEqual(selected, 0)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Centered opaque App Space stack after fast flick"
        capture.lifetime = .keepAlways
        add(capture)
        let quickStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5))
        quickStart.press(forDuration: 0.01, thenDragTo: quickStart.withOffset(CGVector(dx: -60, dy: 0)),
            withVelocity: XCUIGestureVelocity(rawValue: 3000), thenHoldForDuration: 0)
        XCTAssertTrue(wait { card.exists && (readiness.value as? String)?.contains("phase=idle") == true })
        guard let quickDigits = card.label.components(separatedBy: "Workspace conversation ").last?
            .prefix(while: { $0.isNumber }), let quickSelection = Int(quickDigits) else {
            XCTFail("A short fast canvas swipe lost the selected conversation: \(card.label)")
            return
        }
        XCTAssertGreaterThan(quickSelection, selected, "Short swipes on the App Space canvas must respond too")
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 0)
        card.tap()
        XCTAssertTrue(wait { (app.otherElements["surface-lift-state-probe"].value as? String) == "full" })
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 1)
        XCTAssertTrue(app.descendants(matching: .any)["conversation-pane-preview-ui-\(quickSelection)"].exists)
    }

    @MainActor
    private func dragHistoryCard(_ card: XCUIElement, towardOlder: Bool, readiness: XCUIElement) {
        // Keep the observed 200-point path and one gesture. An explicit contact
        // phase separates touch admission from movement on a busy simulator;
        // the independent native-swipe case still covers ordinary and fast flicks.
        let center = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let direction: CGFloat = towardOlder ? 1 : -1
        let start = center.withOffset(CGVector(dx: -100 * direction, dy: 0))
        let end = center.withOffset(CGVector(dx: 100 * direction, dy: 0))
        print("BROWSE_DRAG card=\(card.label) frame=\(card.frame) start=\(start.screenPoint) end=\(end.screenPoint) native=\(readiness.value ?? "missing")")
        start.press(forDuration: 0.05, thenDragTo: end,
            withVelocity: XCUIGestureVelocity(rawValue: 1000), thenHoldForDuration: 0)
    }

    @MainActor
    private func wait(_ condition: @escaping () -> Bool) -> Bool {
        let pending = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [pending], timeout: 10) == .completed
    }
}

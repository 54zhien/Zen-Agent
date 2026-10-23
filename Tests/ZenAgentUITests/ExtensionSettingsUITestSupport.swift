import XCTest

extension XCTestCase {
    @MainActor
    func waitForExtension(_ condition: @escaping () -> Bool) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)], timeout: 5) == .completed
    }

    @MainActor
    func openExtensionSettings(_ app: XCUIApplication, id: String, title: String) -> Bool {
        app.openWorkspaceSidebar()
        let settings = app.buttons["sidebar-settings"]
        guard settings.waitForExistence(timeout: 5) else { XCTFail("Settings entry missing"); return false }
        settings.tap()
        let agent = app.buttons["settings-agent"]
        guard tapExtensionLabel(agent.staticTexts.firstMatch, in: app) else { return false }
        guard app.navigationBars["Agent"].waitForExistence(timeout: 5) else { XCTFail("Agent destination missing"); return false }
        let entry = app.buttons[id]
        guard entry.waitForExistence(timeout: 5) else { captureExtension("Missing \(title) entry", app); XCTFail("Formal \(title) entry missing"); return false }
        guard tapExtensionLabel(entry.staticTexts.firstMatch, in: app) else { return false }
        guard app.navigationBars[title].waitForExistence(timeout: 5) else { captureExtension("Missing \(title) destination", app); XCTFail("\(title) did not open"); return false }
        return true
    }

    @MainActor
    func tapExtensionLabel(_ label: XCUIElement, in app: XCUIApplication, tap: Bool = true) -> Bool {
        for _ in 0..<24 {
            let form = app.collectionViews.firstMatch
            guard form.exists else { break }
            var viewport = form.frame.intersection(app.frame)
            let nav = app.navigationBars.firstMatch
            if nav.exists {
                let top = max(viewport.minY, nav.frame.maxY)
                viewport = CGRect(x: viewport.minX, y: top, width: viewport.width, height: max(0, viewport.maxY - top))
            }
            let track = form.descendants(matching: .other).matching(NSPredicate(format: "label BEGINSWITH %@", "Vertical scroll bar")).firstMatch
            if track.exists, track.frame.height > 0 {
                let frame = CGRect(x: viewport.minX, y: track.frame.minY, width: viewport.width, height: track.frame.height)
                if viewport.intersects(frame) { viewport = viewport.intersection(frame) }
            }
            viewport = viewport.insetBy(dx: 4, dy: 4)
            guard !viewport.isEmpty, !viewport.isNull else { break }
            let target = label.exists ? label.frame : .null
            if !target.isNull, !target.isEmpty, viewport.contains(target), label.isHittable {
                if tap { label.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
                return true
            }
            let down = !target.isNull && target.minY < viewport.minY
            let upper = max(0.1, (viewport.minY - app.frame.minY + 8) / app.frame.height)
            let lower = min(0.9, (viewport.maxY - app.frame.minY - 8) / app.frame.height)
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? upper : lower))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? lower : upper))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: 100, thenHoldForDuration: 0.2)
        }
        captureExtension("Extension route not visible", app)
        XCTFail("Extension control did not become visible")
        return false
    }

    @MainActor
    func captureExtension(_ title: String, _ app: XCUIApplication) {
        let tree = XCTAttachment(string: app.debugDescription); tree.name = title + " hierarchy"; tree.lifetime = .keepAlways; add(tree)
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); image.name = title; image.lifetime = .keepAlways; add(image)
    }
}

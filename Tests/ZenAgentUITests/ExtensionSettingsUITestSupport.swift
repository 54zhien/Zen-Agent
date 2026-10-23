import XCTest

extension XCTestCase {
    @MainActor
    func configureExtensionComposer(_ app: XCUIApplication) -> Bool {
        guard app.textViews["conversation-composer-input"].waitForExistence(timeout: 15) else {
            XCTFail("New Conversation editor missing"); return false
        }
        app.openWorkspaceSidebar()
        let configure = app.buttons["new-conversation-configure"]
        guard configure.waitForExistence(timeout: 5) else { XCTFail("Formal Configure entry missing"); return false }
        configure.tap()
        app.buttons["settings-models"].tap()
        let use = app.buttons["用于当前会话"]
        guard use.waitForExistence(timeout: 5) else { XCTFail("Existing account model missing"); return false }
        use.tap()
        guard app.staticTexts["settings-conversation-configuration-status"].waitForExistence(timeout: 5) else {
            captureExtension("Conversation configuration did not complete", app)
            XCTFail("Current Conversation was not configured"); return false
        }
        app.buttons["settings-close"].tap()
        guard app.buttons["conversation-composer-plus"].waitForExistence(timeout: 5) else {
            XCTFail("Configured Composer actions missing"); return false
        }
        return true
    }

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
        guard tapExtensionLabel(agent.staticTexts.firstMatch, in: app, tap: false) else { return false }
        // At largest type the DEBUG preview-position control covers the label's
        // center. The same measured NavigationLink has an unobstructed right side.
        agent.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        guard app.navigationBars["Agent"].waitForExistence(timeout: 5) else { XCTFail("Agent destination missing"); return false }
        let entry = app.buttons[id]
        guard entry.waitForExistence(timeout: 5) else { captureExtension("Missing \(title) entry", app); XCTFail("Formal \(title) entry missing"); return false }
        guard tapExtensionLabel(entry.staticTexts.firstMatch, in: app) else { return false }
        guard app.navigationBars[title].waitForExistence(timeout: 5) else { captureExtension("Missing \(title) destination", app); XCTFail("\(title) did not open"); return false }
        return true
    }

    @MainActor
    func tapExtensionLabel(_ label: XCUIElement, in app: XCUIApplication, tap: Bool = true,
                           allowPartial: Bool = false) -> Bool {
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
            // Read-only instructions can be taller than the entire viewport at
            // accessibility sizes. Reveal a readable part without requiring the
            // impossible whole-row fit; interactive targets still require it.
            let visible = allowPartial && !tap
                ? viewport.intersection(target).height >= min(44, target.height)
                : viewport.contains(target) && label.isHittable
            if !target.isNull, !target.isEmpty, visible {
                if tap { label.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
                return true
            }
            let down = !target.isNull && target.minY < viewport.minY
            let upper = (viewport.minY + viewport.height * 0.25 - form.frame.minY) / form.frame.height
            let lower = (viewport.maxY - viewport.height * 0.25 - form.frame.minY) / form.frame.height
            let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? upper : lower))
            let end = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? lower : upper))
            print("EXTENSION_FORM_DRAG viewport=\(viewport) target=\(target) start=\(start.screenPoint) end=\(end.screenPoint)")
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

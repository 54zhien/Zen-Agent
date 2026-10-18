import XCTest

final class SplitKeyboardUITests: XCTestCase {
    @MainActor
    func testTwoConversationsKeepTheirDraftsReadingAndRatioAcrossKeyboardCycles() throws {
        try assertKeyboardCycles(occupied: true)
    }

    @MainActor
    func testConversationAndPickerFillTheKeyboardViewportAndKeepTheirState() throws {
        try assertKeyboardCycles(occupied: false)
    }

    @MainActor
    func testTwoConversationsWithSourceBelowKeepTheirStateAcrossKeyboardCycles() throws {
        try assertKeyboardCycles(occupied: true, sourceInTopPane: false)
    }

    @MainActor
    func testPickerAboveConversationRestoresItsViewportAfterKeyboardHides() throws {
        try assertKeyboardCycles(occupied: false, sourceInTopPane: false)
    }

    @MainActor
    private func assertKeyboardCycles(occupied: Bool, sourceInTopPane: Bool = true) throws {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launchEnvironment["ZEN_SPLIT_KEYBOARD_STRESS_UI_TEST"] = "1"
        app.launch()
        app.openWorkspaceSplit(sourceInTopPane: sourceInTopPane)
        if occupied {
            let history = app.buttons["split-history-preview-ui-10"]
            XCTAssertTrue(history.waitForExistence(timeout: 10)); history.tap()
            XCTAssertTrue(app.scrollViews["conversation-pane-preview-ui-10"].waitForExistence(timeout: 10))
        }
        let source = app.scrollViews["conversation-pane-preview-ui-11"]
        let sourceProbe = app.descendants(matching: .any)["surface-native-interaction-probe"]
        let otherProbe = app.descendants(matching: .any)["split-secondary-native-interaction-probe"]
        let viewport = app.descendants(matching: .any)["split-viewport-probe"]
        let divider = app.descendants(matching: .any)["split-divider"]
        let handle = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        handle.press(forDuration: 0.15, thenDragTo: handle.withOffset(CGVector(dx: 0, dy: 40)))
        expect { self.field("ratio", viewport) != nil && self.field("ratio", viewport) != "0.5" }
        let ratio = try XCTUnwrap(field("ratio", viewport))
        let editor = app.textViews["conversation-composer-input"]
        app.activateWorkspacePane("preview-ui-11")
        editor.tap(); editor.typeText("source keyboard viewport draft")
        let sourceIdentity = try XCTUnwrap(field("editorIdentity", sourceProbe))
        try dismissKeyboard(app, editor: editor, probe: sourceProbe)
        var otherIdentity: String?
        if occupied {
            app.activateWorkspacePane("preview-ui-10")
            editor.tap(); editor.typeText("other keyboard viewport draft")
            otherIdentity = try XCTUnwrap(field("editorIdentity", otherProbe))
            try dismissKeyboard(app, editor: editor, probe: otherProbe)
            app.activateWorkspacePane("preview-ui-11")
        }
        let position = app.buttons["preview-reading-position"]
        XCTAssertTrue(position.exists); position.tap()
        expect { (position.value as? String) == "settled" }
        let anchor = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ OR value == %@", "PREVIEW_READING_ANCHOR_10",
            "PREVIEW_READING_ANCHOR_10")).firstMatch
        XCTAssertTrue(anchor.exists && anchor.isHittable)
        let bottomDistance = source.frame.maxY - anchor.frame.minY
        let picker = app.descendants(matching: .any)["split-empty-pane-picker"]
        let restingSource = try XCTUnwrap(rect("surfaceFrame", sourceProbe))
        let restingOther: CGRect
        if occupied { restingOther = try XCTUnwrap(rect("surfaceFrame", otherProbe)) }
        else { restingOther = picker.frame }
        let restingDivider = divider.frame
        // Exercise the shared input from either owner, plus either picker placement.
        let activeIDs = occupied ? ["preview-ui-11", "preview-ui-10"] : ["preview-ui-11"]

        for activeID in activeIDs {
            app.activateWorkspacePane(activeID)
            let activeProbe = activeID == "preview-ui-11" ? sourceProbe : otherProbe
            let draft = activeID == "preview-ui-11" ? "source keyboard viewport draft" : "other keyboard viewport draft"
            app.buttons["split-keyboard-stress-start"].tap()
            assertTransitionSamples(app, rapid: true)
            expect { !app.keyboards.firstMatch.exists }
            XCTAssertEqual(field("ratio", viewport), ratio)
            XCTAssertEqual(field("editorIdentity", sourceProbe), sourceIdentity)
            if occupied { XCTAssertEqual(field("editorIdentity", otherProbe), otherIdentity) }
            XCTAssertTrue((editor.value as? String)?.contains(draft) == true)
            for _ in 0..<2 {
                editor.tap()
                XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
                expect {
                    guard self.surfaceFillsContent(sourceProbe),
                          let sourceFrame = self.rect("surfaceFrame", sourceProbe) else { return false }
                    let otherFrame: CGRect
                    if occupied {
                        guard self.surfaceFillsContent(otherProbe),
                              let frame = self.rect("surfaceFrame", otherProbe) else { return false }
                        otherFrame = frame
                    } else {
                        guard picker.exists else { return false }
                        otherFrame = picker.frame
                    }
                    let upper = sourceInTopPane ? sourceFrame : otherFrame
                    let lower = sourceInTopPane ? otherFrame : sourceFrame
                    // Settled geometry and the actual Composer gap must agree; merely
                    // observing keyboard existence can still sample an unfinished layout.
                    guard let gap = self.number("keyboardGap", activeProbe),
                          let spacing = self.number("bottomSpacing", activeProbe) else { return false }
                    return abs(upper.minY - min(restingSource.minY, restingOther.minY)) < 2
                        && abs(upper.maxY - divider.frame.minY) < 2
                        && abs(lower.minY - divider.frame.maxY) < 2
                        && abs(lower.maxY - app.keyboards.firstMatch.frame.minY) < 2
                        && abs(gap - spacing) <= 0.5
                }
                XCTAssertEqual(field("ratio", viewport), ratio)
                XCTAssertEqual(field("editorIdentity", sourceProbe), sourceIdentity)
                if occupied { XCTAssertEqual(field("editorIdentity", otherProbe), otherIdentity) }
                XCTAssertTrue((editor.value as? String)?.contains(draft) == true)
                try dismissKeyboard(app, editor: editor, probe: activeProbe)
                expect {
                    guard self.surfaceFillsContent(sourceProbe),
                          let sourceFrame = self.rect("surfaceFrame", sourceProbe),
                          self.matches(sourceFrame, restingSource),
                          self.matches(divider.frame, restingDivider) else { return false }
                    if occupied {
                        guard self.surfaceFillsContent(otherProbe),
                              let otherFrame = self.rect("surfaceFrame", otherProbe) else { return false }
                        return self.matches(otherFrame, restingOther)
                    }
                    return picker.exists && self.matches(picker.frame, restingOther)
                }
                expect { anchor.isHittable && abs(source.frame.maxY - anchor.frame.minY - bottomDistance) < 4 }
                XCTAssertEqual(field("ratio", viewport), ratio)
            }
        }
        if occupied {
            app.activateWorkspacePane("preview-ui-10")
            XCTAssertTrue((editor.value as? String)?.contains("other keyboard viewport draft") == true)
            XCTAssertEqual(field("editorIdentity", otherProbe), otherIdentity)
        }
        app.activateWorkspacePane("preview-ui-11")
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        app.buttons["split-keyboard-watch-start"].tap()
        app.openWorkspaceSidebar()
        assertTransitionSamples(app, rapid: false)
        expect {
            guard !app.keyboards.firstMatch.exists,
                  self.surfaceFillsContent(sourceProbe),
                  let sourceFrame = self.rect("surfaceFrame", sourceProbe),
                  self.matchesVertical(sourceFrame, restingSource),
                  self.matchesVertical(divider.frame, restingDivider) else { return false }
            if occupied {
                guard self.surfaceFillsContent(otherProbe),
                      let otherFrame = self.rect("surfaceFrame", otherProbe) else { return false }
                return self.matchesVertical(otherFrame, restingOther)
            }
            return picker.exists && self.matchesVertical(picker.frame, restingOther)
        }
        XCTAssertEqual(field("ratio", viewport), ratio)
        XCTAssertEqual(field("editorIdentity", sourceProbe), sourceIdentity)
        XCTAssertTrue((editor.value as? String)?.contains("source keyboard viewport draft") == true)
    }

    @MainActor
    private func assertTransitionSamples(_ app: XCUIApplication, rapid: Bool) {
        let probe = app.descendants(matching: .any)["split-keyboard-stress-probe"]
        expect { self.field("status", probe) == "done" }
        let metrics = probe.value as? String ?? "missing probe"
        print("SPLIT_KEYBOARD_SAMPLES rapid=\(rapid) \(metrics)")
        let attachment = XCTAttachment(string: metrics)
        attachment.name = rapid ? "Rapid keyboard presentation samples" : "Sidebar keyboard overlap samples"
        attachment.lifetime = .keepAlways
        add(attachment)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = rapid ? "After rapid keyboard reversals" : "After Sidebar keyboard dismissal"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertGreaterThanOrEqual(number("samples", probe) ?? 0, 6)
        XCTAssertEqual(number("missing", probe), 0)
        XCTAssertLessThanOrEqual(number("underfill", probe) ?? .infinity, 2)
        XCTAssertLessThanOrEqual(number("partitionError", probe) ?? .infinity, 2)
        if rapid {
            XCTAssertEqual(number("requests", probe), 12)
            XCTAssertGreaterThanOrEqual(number("keyboardEvents", probe) ?? 0, 2)
            XCTAssertGreaterThan(number("retargeted", probe) ?? 0, 0,
                                 "The stimulus must actually interrupt a keyboard transition")
        } else {
            XCTAssertGreaterThan(number("keyboardEvents", probe) ?? 0, 0)
            XCTAssertGreaterThan(number("sidebarSamples", probe) ?? 0, 0,
                                 "Sampling must overlap the real Sidebar gesture")
            XCTAssertGreaterThan(number("overlap", probe) ?? 0, 0,
                                 "A display tick must include Sidebar transport during UIKit's reported keyboard transition")
        }
    }

    @MainActor
    private func surfaceFillsContent(_ probe: XCUIElement) -> Bool {
        guard field("workspaceOwnsKeyboard", probe) == "true",
              let surface = rect("surfaceFrame", probe),
              let content = rect("contentFrame", probe) else { return false }
        return matches(surface, content)
    }

    private func matches(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 2 && abs(lhs.minY - rhs.minY) < 2
            && abs(lhs.width - rhs.width) < 2 && abs(lhs.height - rhs.height) < 2
    }

    private func matchesVertical(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minY - rhs.minY) < 2 && abs(lhs.height - rhs.height) < 2
    }

    @MainActor
    private func number(_ key: String, _ element: XCUIElement) -> Double? {
        field(key, element).flatMap(Double.init)
    }

    @MainActor
    private func dismissKeyboard(_ app: XCUIApplication, editor: XCUIElement, probe: XCUIElement) throws {
        let readable = try XCTUnwrap(rect("timelineVisibleFrame", probe))
        let point = CGPoint(x: readable.maxX - 8, y: min(editor.frame.minY - 30, readable.maxY - 8))
        XCTAssertTrue(readable.contains(point))
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x - app.frame.minX, dy: point.y - app.frame.minY)).tap()
        expect { !app.keyboards.firstMatch.exists }
    }

    @MainActor
    private func field(_ key: String, _ element: XCUIElement) -> String? {
        (element.value as? String)?.components(separatedBy: ";")
            .first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
    }

    @MainActor
    private func rect(_ key: String, _ element: XCUIElement) -> CGRect? {
        guard let value = field(key, element), value.first == "(", value.last == ")" else { return nil }
        let numbers = value.dropFirst().dropLast().split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard numbers.count == 4 else { return nil }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    @MainActor
    private func expect(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let pending = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [pending], timeout: 10), .completed, file: file, line: line)
    }
}

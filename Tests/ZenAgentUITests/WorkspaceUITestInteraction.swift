import XCTest

@MainActor
extension XCUIApplication {
    /// Upper-source entry exercises the real Composer drag. Lower-source keyboard
    /// fixtures use an explicit arrangement setup, not a synthetic private gesture.
    func openWorkspaceSplit(sourceInTopPane: Bool = true,
                            file: StaticString = #filePath, line: UInt = #line) {
        let editor = textViews["conversation-composer-input"]
        guard editor.waitForExistence(timeout: 15) else {
            XCTFail("Split requires the mounted Composer", file: file, line: line)
            return
        }
        if !sourceInTopPane {
            let setup = buttons["preview-bottom-source-split"]
            guard setup.waitForExistence(timeout: 10) else {
                XCTFail("Lower-source cases must opt into their arrangement fixture", file: file, line: line)
                return
            }
            setup.tap()
            XCTAssertTrue(descendants(matching: .any)["split-empty-pane-picker"].waitForExistence(timeout: 10),
                file: file, line: line)
            return
        }
        let probe = descendants(matching: .any)["surface-native-interaction-probe"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (probe.value as? String)?.contains("liftReady=true;") == true
        }, object: nil)
        guard XCTWaiter.wait(for: [ready], timeout: 10) == .completed else {
            XCTFail("Split requires native Lift readiness: \(String(describing: probe.value))", file: file, line: line)
            return
        }
        let start = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 1,
            thenDragTo: coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)))
        let opened = descendants(matching: .any)["split-empty-pane-picker"].waitForExistence(timeout: 10)
        XCTAssertTrue(opened, "Composer drag must open the Split picker", file: file, line: line)
        if !opened {
            print("SPLIT_ENTRY_FAILURE \(probe.value as? String ?? "missing native probe")")
        }
    }

    func openWorkspaceSidebar(file: StaticString = #filePath, line: UInt = #line) {
        let rail = descendants(matching: .any)["sidebar-rail"]
        XCTAssertTrue(textViews["conversation-composer-input"].waitForExistence(timeout: 15), file: file, line: line)
        let probes = [descendants(matching: .any)["surface-native-interaction-probe"],
                      descendants(matching: .any)["split-secondary-native-interaction-probe"]]
        if !rail.exists { dismissWorkspaceInputForSidebar(file: file, line: line) }
        if probes.contains(where: { $0.exists }) {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                probes.contains { ($0.value as? String)?.contains(";sidebarCanOpen=true;") == true }
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, file: file, line: line)
        }
        if !rail.exists {
            dragWorkspaceSidebarEdge()
        }
        guard rail.waitForExistence(timeout: 10) else {
            let receipt = probes.filter { $0.exists }.map { String(describing: $0.value) }.joined(separator: "\n")
            XCTFail("Sidebar did not open after one edge gesture. Native receipt: \(receipt)", file: file, line: line)
            return
        }
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let native = probes.filter { $0.exists }
            return (native.isEmpty || native.contains {
                ($0.value as? String)?.contains("sidebar=open=true,progress=1.0,drag=false,settlement=nil") == true
            }) && self.buttons["sidebar-settings"].isEnabled
                && self.buttons["sidebar-settings"].isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 10), .completed,
            "Sidebar controls must be hittable after native opening settles: \(probes.filter { $0.exists }.map { String(describing: $0.value) })",
            file: file, line: line)
    }

    /// The first edge gesture belongs to the raised input owner; it must not
    /// silently become a second attempt to open Sidebar after input disappears.
    func dismissWorkspaceInputForSidebar(file: StaticString = #filePath, line: UInt = #line) {
        let sheet = descendants(matching: .any)["composer-keyboard-sheet"]
        guard keyboards.firstMatch.exists || sheet.exists else { return }
        let rail = descendants(matching: .any)["sidebar-rail"]
        let probes = [descendants(matching: .any)["surface-native-interaction-probe"],
                      descendants(matching: .any)["split-secondary-native-interaction-probe"]]
        XCTAssertFalse(rail.exists, file: file, line: line)
        dragWorkspaceSidebarEdge()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let native = probes.filter { $0.exists }
            return !self.keyboards.firstMatch.exists && !sheet.exists && !rail.exists
                && (native.isEmpty || native.allSatisfy {
                    ($0.value as? String)?.contains("sidebar=open=false,progress=0.0,drag=false,settlement=nil") == true
                })
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 10), .completed,
            "The first edge swipe dismisses input without opening Sidebar", file: file, line: line)
    }

    func dragWorkspaceSidebarEdge(at verticalPosition: CGFloat = 0.3) {
        let viewport = frame
        // Both endpoints belong to the app's axes. An absolute screen offset
        // after resolving the first point can use a different axis in landscape.
        let start = coordinate(withNormalizedOffset: CGVector(dx: 0.001, dy: verticalPosition))
        let end = coordinate(withNormalizedOffset: CGVector(dx: 0.001 + 110 / viewport.width,
                                                            dy: verticalPosition))
        print("SIDEBAR_EDGE_PATH viewport=\(viewport) start=\(start.screenPoint) end=\(end.screenPoint) oldAbsoluteEnd=\(start.withOffset(CGVector(dx: 110, dy: 0)).screenPoint)")
        start.press(forDuration: 0.2, thenDragTo: end)
    }

    func activateWorkspacePane(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let pane = scrollViews.matching(identifier: "conversation-pane-\(id)").firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 10), file: file, line: line)
        pane.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.3)).tap()
    }

    /// Exercise the real Timeline blank-background path, including safe-area
    /// containment. AX Pane bounds alone include regions outside that path.
    func dismissWorkspaceKeyboard(pane: XCUIElement, editor: XCUIElement,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let probe = descendants(matching: .any)["surface-native-interaction-probe"]
        guard let point = workspaceTimelineBlankPoint(pane: pane, editor: editor, file: file, line: line),
              let previous = timelineTapSequence(probe) else {
            XCTFail("Expected a native Timeline tap sequence and viewport", file: file, line: line)
            return
        }
        coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: point.x - frame.minX, dy: point.y - frame.minY)).tap()
        let dismissal = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !self.keyboards.firstMatch.exists && (self.timelineTapSequence(probe) ?? previous) > previous
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissal], timeout: 10), .completed, file: file, line: line)
        XCTAssertTrue((probe.value as? String)?.contains(";blank=true;") == true, file: file, line: line)
    }

    func workspaceTimelineBlankPoint(pane: XCUIElement, editor: XCUIElement, preferLeading: Bool = false,
                                    file: StaticString = #filePath, line: UInt = #line) -> CGPoint? {
        let probe = descendants(matching: .any)["surface-native-interaction-probe"]
        guard let field = (probe.value as? String)?.split(separator: ";")
            .first(where: { $0.hasPrefix("timelineVisibleFrame=(") }) else {
            XCTFail("Expected a native Timeline viewport", file: file, line: line)
            return nil
        }
        let values = field.dropFirst("timelineVisibleFrame=(".count).dropLast().split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard values.count == 4 else { XCTFail("Invalid native viewport", file: file, line: line); return nil }
        let readable = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        let point = CGPoint(x: preferLeading ? readable.minX + 8 : readable.maxX - 8,
            y: min(readable.maxY - 8, max(readable.minY + 8, editor.frame.minY - 30)))
        XCTAssertTrue(readable.contains(point), file: file, line: line)
        XCTAssertTrue(pane.frame.contains(point), file: file, line: line)
        XCTAssertTrue(frame.contains(point), file: file, line: line)
        if keyboards.firstMatch.exists {
            XCTAssertLessThan(point.y, keyboards.firstMatch.frame.minY, file: file, line: line)
        }
        return point
    }

    private func timelineTapSequence(_ probe: XCUIElement) -> UInt64? {
        (probe.value as? String)?.split(separator: ";").first { $0.hasPrefix("blankTapSequence=") }
            .flatMap { UInt64($0.dropFirst("blankTapSequence=".count)) }
    }
}

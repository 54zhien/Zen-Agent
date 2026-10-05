import XCTest

@MainActor
extension XCUIApplication {
    func openWorkspaceSidebar(file: StaticString = #filePath, line: UInt = #line) {
        let rail = descendants(matching: .any)["sidebar-rail"]
        if rail.exists { return }
        XCTAssertTrue(textViews["conversation-composer-input"].waitForExistence(timeout: 15), file: file, line: line)
        let probes = [descendants(matching: .any)["surface-native-interaction-probe"],
                      descendants(matching: .any)["split-secondary-native-interaction-probe"]]
        if probes.contains(where: { $0.exists }) {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                probes.contains { ($0.value as? String)?.contains(";sidebarCanOpen=true;") == true }
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, file: file, line: line)
        }
        let edge = coordinate(withNormalizedOffset: CGVector(dx: 0.001, dy: 0.3))
        edge.press(forDuration: 0.05, thenDragTo: edge.withOffset(CGVector(dx: 110, dy: 0)))
        guard rail.waitForExistence(timeout: 10) else {
            let receipt = probes.filter { $0.exists }.map { String(describing: $0.value) }.joined(separator: "\n")
            XCTFail("Sidebar did not open after one edge gesture. Native receipt: \(receipt)", file: file, line: line)
            return
        }
        XCTAssertTrue(buttons["sidebar-settings"].wait(for: \.isEnabled, toEqual: true, timeout: 10), file: file, line: line)
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
        XCTAssertLessThan(point.y, keyboards.firstMatch.frame.minY, file: file, line: line)
        return point
    }

    private func timelineTapSequence(_ probe: XCUIElement) -> UInt64? {
        (probe.value as? String)?.split(separator: ";").first { $0.hasPrefix("blankTapSequence=") }
            .flatMap { UInt64($0.dropFirst("blankTapSequence=".count)) }
    }
}

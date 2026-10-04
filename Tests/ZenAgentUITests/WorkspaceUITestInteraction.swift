import XCTest

@MainActor
extension XCUIApplication {
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

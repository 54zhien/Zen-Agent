import XCTest
import UIKit

final class WorkspacePadAxisUITests: XCTestCase {
    @MainActor
    func testNativeAxisMenuPreservesBothEditorsAndSeparateRatios() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("This regression needs an iPad simulator destination")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launch()
        let entry = app.buttons["split-entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15))
        entry.tap()
        app.buttons["split-open-top"].tap()
        let history = app.buttons["split-history-preview-ui-10"]
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        history.tap()
        let source = app.scrollViews.matching(identifier: "conversation-pane-preview-ui-11").firstMatch
        let other = app.scrollViews.matching(identifier: "conversation-pane-preview-ui-10").firstMatch
        expect { source.exists && other.exists && app.frame.width > app.frame.height }
        let sourceProbe = app.descendants(matching: .any)["surface-native-interaction-probe"]
        let otherProbe = app.descendants(matching: .any)["split-secondary-native-interaction-probe"]
        let sourceIdentity = try XCTUnwrap(editorIdentity(sourceProbe.value as? String))
        let otherIdentity = try XCTUnwrap(editorIdentity(otherProbe.value as? String))
        let verticalHeight = source.frame.height
        selectAxis("左右分屏", in: app)
        expect { abs(source.frame.maxX - other.frame.minX) < 3
            && source.frame.height > verticalHeight + 50 && self.leasesReleased(sourceProbe, otherProbe) }
        XCTAssertEqual(source.frame.height, other.frame.height, accuracy: 3)
        let widthBefore = source.frame.width
        let handle = app.descendants(matching: .any)["split-divider-handle"]
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.15, thenDragTo: start.withOffset(CGVector(dx: 100, dy: 0)))
        expect { source.frame.width > widthBefore + 50 && self.leasesReleased(sourceProbe, otherProbe) }
        let horizontalWidth = source.frame.width
        selectAxis("上下分屏", in: app)
        expect { abs(source.frame.height - verticalHeight) < 4 && self.leasesReleased(sourceProbe, otherProbe) }
        selectAxis("左右分屏", in: app)
        expect { abs(source.frame.width - horizontalWidth) < 4 && self.leasesReleased(sourceProbe, otherProbe) }
        XCTAssertEqual(editorIdentity(sourceProbe.value as? String), sourceIdentity)
        XCTAssertEqual(editorIdentity(otherProbe.value as? String), otherIdentity)
        XCTAssertTrue(source.exists && other.exists)
    }

    @MainActor
    private func selectAxis(_ title: String, in app: XCUIApplication) {
        let handle = app.descendants(matching: .any)["split-divider-handle"]
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.8)
        let action = app.buttons[title]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        action.tap()
    }

    private func editorIdentity(_ diagnostic: String?) -> String? {
        diagnostic?.split(separator: ";").first { $0.hasPrefix("editorIdentity=") }.map(String.init)
    }

    @MainActor
    private func leasesReleased(_ source: XCUIElement, _ other: XCUIElement) -> Bool {
        (source.value as? String)?.contains(";lease=false;") == true
            && (other.value as? String)?.contains(";lease=false;") == true
    }

    @MainActor
    private func expect(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let pending = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [pending], timeout: 10), .completed, file: file, line: line)
    }
}

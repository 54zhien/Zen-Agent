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
        let splitAction = app.buttons["split-open-top"]
        guard splitAction.waitForExistence(timeout: 10) else {
            XCTFail("Split menu did not become available after opening it")
            return
        }
        splitAction.tap()
        let history = app.buttons["split-history-preview-ui-10"]
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        history.tap()
        let source = app.scrollViews.matching(identifier: "conversation-pane-preview-ui-11").firstMatch
        let other = app.scrollViews.matching(identifier: "conversation-pane-preview-ui-10").firstMatch
        // Each AX request can block independently on a busy simulator. Observe
        // these stable prerequisites separately before starting the next input.
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        XCTAssertTrue(other.waitForExistence(timeout: 10))
        // Synchronous AX frame reads can outlive a predicate waiter. After both
        // existence gates, require the first native geometry sample to be ready.
        let sourceFrame = source.frame
        let otherFrame = other.frame
        let initialViewport = sourceFrame.union(otherFrame)
        print("PAD_INITIAL_GEOMETRY source=\(sourceFrame) other=\(otherFrame) viewport=\(initialViewport)")
        guard [sourceFrame, otherFrame].allSatisfy({ frame in
            !frame.isNull && !frame.isEmpty && frame.width > 0 && frame.height > 0 &&
                [frame.minX, frame.minY, frame.width, frame.height].allSatisfy { $0.isFinite }
        }), initialViewport.width.isFinite, initialViewport.height.isFinite else {
            XCTFail("Initial native Pane geometry is invalid: \(sourceFrame), \(otherFrame)")
            return
        }
        XCTAssertGreaterThan(initialViewport.width, initialViewport.height,
                             "Initial native workspace must already be landscape")
        let sourceProbe = app.descendants(matching: .any)["surface-native-interaction-probe"]
        let otherProbe = app.descendants(matching: .any)["split-secondary-native-interaction-probe"]
        let sourceIdentity = try XCTUnwrap(editorIdentity(sourceProbe.value as? String))
        let otherIdentity = try XCTUnwrap(editorIdentity(otherProbe.value as? String))
        let verticalHeight = source.frame.height
        selectAxis("左右分屏", in: app)
        expect { source.frame.height > verticalHeight + 50 }
        expectLeasesReleased(sourceProbe, otherProbe)
        XCTAssertEqual(source.frame.maxX, other.frame.minX, accuracy: 3)
        XCTAssertEqual(source.frame.height, other.frame.height, accuracy: 3)
        let widthBefore = source.frame.width
        let handle = app.descendants(matching: .any)["split-divider-handle"]
        let handleFrame = handle.frame
        let viewport = app.frame
        // XCUICoordinate is relative to a live element. The divider moves during
        // this gesture, so anchor both endpoints to the stable app viewport.
        let start = app.coordinate(withNormalizedOffset: CGVector(
            dx: (handleFrame.midX - viewport.minX) / viewport.width,
            dy: (handleFrame.midY - viewport.minY) / viewport.height))
        let end = app.coordinate(withNormalizedOffset: CGVector(
            dx: (handleFrame.midX + 100 - viewport.minX) / viewport.width,
            dy: (handleFrame.midY - viewport.minY) / viewport.height))
        print("PAD_DRAG_START screen=\(start.screenPoint) end=\(end.screenPoint) anchor=app handle=\(handle.frame) value=\(String(describing: handle.value))")
        start.press(forDuration: 0.15, thenDragTo: end,
            withVelocity: .slow, thenHoldForDuration: 0)
        print("PAD_RESIZE beforeWidth=\(widthBefore) source=\(source.frame) other=\(other.frame) handle=\(handle.frame) value=\(String(describing: handle.value))")
        print("PAD_SOURCE \(String(describing: sourceProbe.value))")
        print("PAD_OTHER \(String(describing: otherProbe.value))")
        expect { source.frame.width > widthBefore + 50 }
        expectLeasesReleased(sourceProbe, otherProbe)
        let horizontalWidth = source.frame.width
        selectAxis("上下分屏", in: app)
        expect { abs(source.frame.height - verticalHeight) < 4 }
        expectLeasesReleased(sourceProbe, otherProbe)
        selectAxis("左右分屏", in: app)
        expect { abs(source.frame.width - horizontalWidth) < 4 }
        expectLeasesReleased(sourceProbe, otherProbe)
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
        expect { (handle.value as? String)?.contains(";dividerReady=true;") == true }
        print("PAD_AXIS_READY \(String(describing: handle.value))")
    }

    private func editorIdentity(_ diagnostic: String?) -> String? {
        diagnostic?.split(separator: ";").first { $0.hasPrefix("editorIdentity=") }.map(String.init)
    }

    @MainActor
    private func expectLeasesReleased(_ source: XCUIElement, _ other: XCUIElement) {
        expect { (source.value as? String)?.contains(";lease=false;") == true }
        expect { (other.value as? String)?.contains(";lease=false;") == true }
    }

    @MainActor
    private func expect(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let pending = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [pending], timeout: 10), .completed, file: file, line: line)
    }
}

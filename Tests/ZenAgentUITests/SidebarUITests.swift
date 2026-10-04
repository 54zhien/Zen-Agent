import XCTest
import UIKit

final class SidebarUITests: XCTestCase {
    @MainActor
    func testLandscapeRailPreservesTheInnerTimelineAndEditorWidths() {
        let app = launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let pane = app.scrollViews.matching(identifier: "conversation-pane-preview-ui-11").firstMatch
        let probe = app.descendants(matching: .any)["surface-native-interaction-probe"]
        let editor = app.textViews["conversation-composer-input"]
        expect { app.frame.width > app.frame.height
            && (self.timelineContainerWidth(probe.value as? String) ?? 0) > 500 }
        guard let timelineWidth = timelineContainerWidth(probe.value as? String) else {
            XCTFail("Expected the inner SwiftUI Timeline width")
            return
        }
        let paneWidth = pane.frame.width
        let editorWidth = editor.frame.width
        let identity = editorIdentity(probe.value as? String)
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.001, dy: 0.4))
        edge.press(forDuration: 0.05, thenDragTo: edge.withOffset(CGVector(dx: 110, dy: 0)))
        let rail = app.descendants(matching: .any)["sidebar-rail"]
        XCTAssertTrue(rail.waitForExistence(timeout: 5))
        XCTAssertEqual(pane.frame.width, paneWidth, accuracy: 2)
        XCTAssertEqual(timelineContainerWidth(probe.value as? String) ?? 0, timelineWidth, accuracy: 2)
        XCTAssertEqual(editor.frame.width, editorWidth, accuracy: 2)
        XCTAssertEqual(editorIdentity(probe.value as? String), identity)
        pane.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        expect { !rail.exists }
        XCTAssertEqual(timelineContainerWidth(probe.value as? String) ?? 0, timelineWidth, accuracy: 2)
    }

    @MainActor
    func testStableEditingCanOpenAndReverseCloseRailWithoutChangingNativeOwner() {
        let app = launch()
        let editor = app.textViews["conversation-composer-input"]
        let probe = app.descendants(matching: .any)["surface-native-interaction-probe"]
        editor.tap()
        editor.typeText("editing sidebar draft")
        expect { app.keyboards.firstMatch.exists
            && (probe.value as? String)?.contains("focused=true;") == true
            && (probe.value as? String)?.contains("keyboardTransitioning: false") == true }
        let identity = editorIdentity(probe.value as? String)
        XCTAssertNotNil(identity)
        let pane = app.scrollViews.matching(identifier: "conversation-pane-preview-ui-11").firstMatch
        let before = pane.frame
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.001, dy: 0.3))
        edge.press(forDuration: 0.05, thenDragTo: edge.withOffset(CGVector(dx: 110, dy: 0)))
        let rail = app.descendants(matching: .any)["sidebar-rail"]
        XCTAssertTrue(rail.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertEqual(pane.frame.width, before.width, accuracy: 2)
        XCTAssertEqual(editorIdentity(probe.value as? String), identity)
        XCTAssertTrue((probe.value as? String)?.contains("focused=true;") == true)
        let closeStart = pane.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        closeStart.press(forDuration: 0.05, thenDragTo: closeStart.withOffset(CGVector(dx: -110, dy: 0)))
        expect { !rail.exists }
        XCTAssertEqual(pane.frame.minX, before.minX, accuracy: 2)
        XCTAssertEqual(editorIdentity(probe.value as? String), identity)
        XCTAssertTrue((editor.value as? String)?.contains("editing sidebar draft") == true)
        XCTAssertTrue((probe.value as? String)?.contains("focused=true;") == true)
    }

    @MainActor
    func testLeadingEdgeRevealsRailWithoutRelayoutAndTapRestoresDraft() {
        let app = launch()
        let pane = app.scrollViews.matching(identifier: "conversation-pane-preview-ui-11").firstMatch
        let editor = app.textViews["conversation-composer-input"]
        editor.tap()
        editor.typeText("retained sidebar draft")
        app.dismissWorkspaceKeyboard(pane: pane, editor: editor)
        let before = pane.frame
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.001, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: edge.withOffset(CGVector(dx: 110, dy: 0)))
        let rail = app.descendants(matching: .any)["sidebar-rail"]
        XCTAssertTrue(rail.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["sidebar-search"].exists)
        XCTAssertTrue(app.buttons["sidebar-files"].exists)
        XCTAssertTrue(app.buttons["sidebar-settings"].exists)
        XCTAssertGreaterThan(pane.frame.minX, before.minX + 30)
        XCTAssertEqual(pane.frame.width, before.width, accuracy: 2)
        XCTAssertFalse(app.buttons["sidebar-open"].exists)
        pane.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.3)).tap()
        expect { !rail.exists }
        XCTAssertEqual(pane.frame.minX, before.minX, accuracy: 2)
        XCTAssertTrue((editor.value as? String)?.contains("retained sidebar draft") == true)
    }

    @MainActor
    func testInteriorSwipeAndSplitCannotRevealRail() {
        let app = launch()
        let interior = app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        interior.press(forDuration: 0.05, thenDragTo: interior.withOffset(CGVector(dx: 110, dy: 0)))
        XCTAssertFalse(app.descendants(matching: .any)["sidebar-rail"].exists)
        app.buttons["split-entry"].tap()
        app.buttons["split-open-top"].tap()
        let picker = app.descendants(matching: .any)["split-empty-pane-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.001, dy: 0.35))
        edge.press(forDuration: 0.05, thenDragTo: edge.withOffset(CGVector(dx: 110, dy: 0)))
        XCTAssertFalse(app.descendants(matching: .any)["sidebar-rail"].exists)
        XCTAssertTrue(picker.exists)
    }

    @MainActor
    func testCardBrowseCannotClaimTheSidebarEdgeGesture() {
        let app = launch()
        let editor = app.textViews["conversation-composer-input"]
        let probe = app.descendants(matching: .any)["surface-native-interaction-probe"]
        expect { (probe.value as? String)?.contains("liftReady=true;") == true }
        let start = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.7, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -220)))
        let card = app.descendants(matching: .any)["workspace-current-card"]
        expect { card.exists }
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.001, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: edge.withOffset(CGVector(dx: 110, dy: 0)))
        XCTAssertFalse(app.descendants(matching: .any)["sidebar-rail"].exists)
        XCTAssertTrue(card.exists)
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 0)
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["split-entry"].waitForExistence(timeout: 15))
        return app
    }

    private func editorIdentity(_ diagnostic: String?) -> String? {
        diagnostic?.split(separator: ";").first { $0.hasPrefix("editorIdentity=") }.map(String.init)
    }

    private func timelineContainerWidth(_ diagnostic: String?) -> Double? {
        diagnostic?.split(separator: ";").first { $0.hasPrefix("container=(") }
            .flatMap { $0.dropFirst("container=(".count).split(separator: ",").first }
            .flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }

    @MainActor
    private func expect(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let pending = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [pending], timeout: 10), .completed, file: file, line: line)
    }
}

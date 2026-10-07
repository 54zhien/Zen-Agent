import XCTest
import UIKit

final class SidebarUITests: XCTestCase {
    @MainActor
    func testSidebarNewReturnsToOriginalUnsentDraftThroughAppSpace() {
        let app = launch()
        app.openWorkspaceSidebar()
        app.buttons["new-conversation-new"].tap()
        let editor = app.textViews["conversation-composer-input"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        editor.typeText("sidebar retained draft")
        expect { (editor.value as? String) == "sidebar retained draft" }
        let pane = app.scrollViews.matching(NSPredicate(format: "identifier BEGINSWITH %@", "conversation-pane-")).firstMatch
        app.dismissWorkspaceKeyboard(pane: pane, editor: editor)
        let probe = app.descendants(matching: .any)["surface-native-interaction-probe"]
        let selection = (probe.value as? String)?.split(separator: ";")
            .first { $0.hasPrefix("editorSelection=") }.map(String.init)
        XCTAssertEqual(selection, "editorSelection=(22,0)")
        app.openWorkspaceSidebar()
        app.buttons["new-conversation-new"].tap()
        expect { (editor.value as? String) == "" }
        let point = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        point.press(forDuration: 0.7, thenDragTo: point.withOffset(CGVector(dx: 0, dy: -220)))
        let card = app.descendants(matching: .any)["workspace-current-card"]
        expect { card.exists }
        card.swipeRight()
        expect { card.exists }
        card.tap()
        expect { (editor.value as? String) == "sidebar retained draft" }
        expect { (probe.value as? String)?.contains(selection ?? "missing-selection") == true }
    }

    @MainActor
    func testSplitSidebarClosingIncludesOppositePaneAndSharedInput() {
        let app = launch()
        app.openWorkspaceSidebar()
        app.buttons["split-entry"].tap()
        app.buttons["split-open-top"].tap()
        let history = app.buttons["split-history-preview-ui-10"]
        XCTAssertTrue(history.waitForExistence(timeout: 10)); history.tap()
        XCTAssertTrue(app.scrollViews["conversation-pane-preview-ui-10"].waitForExistence(timeout: 10))
        let editor = app.textViews["conversation-composer-input"]
        let otherProbe = app.descendants(matching: .any)["split-secondary-native-interaction-probe"]
        let originalIdentity = editorIdentity(otherProbe.value as? String)
        XCTAssertNotNil(originalIdentity)
        let rail = app.descendants(matching: .any)["sidebar-rail"]
        app.openWorkspaceSidebar()
        app.activateWorkspacePane("preview-ui-11")
        expect { !rail.exists }
        XCTAssertEqual(editorIdentity(otherProbe.value as? String), originalIdentity)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        app.openWorkspaceSidebar()
        editor.tap()
        expect { !rail.exists }
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Closing tap must not start editing")
        XCTAssertEqual(editorIdentity(otherProbe.value as? String), originalIdentity)
    }

    @MainActor
    func testShiftedBlankTapClosesRailRetainingFocusAndLaterBlankTapDismissesNormally() {
        let app = launch()
        let pane = app.scrollViews.matching(identifier: "conversation-pane-preview-ui-11").firstMatch
        let editor = app.textViews["conversation-composer-input"]
        let probe = app.descendants(matching: .any)["surface-native-interaction-probe"]
        editor.tap()
        editor.typeText("focused tap close")
        expect { app.keyboards.firstMatch.exists
            && (probe.value as? String)?.contains("keyboardTransitioning: false") == true }
        let identity = editorIdentity(probe.value as? String)
        let originalX = pane.frame.minX
        expect { (probe.value as? String)?.contains(";sidebarCanOpen=true;") == true }
        app.dragWorkspaceSidebarEdge(at: 0.3)
        let rail = app.descendants(matching: .any)["sidebar-rail"]
        receipt("focused-open", probe)
        XCTAssertTrue(rail.waitForExistence(timeout: 5))
        guard let blank = app.workspaceTimelineBlankPoint(pane: pane, editor: editor, preferLeading: true) else { return }
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: blank.x, dy: blank.y)).tap()
        receipt("focused-close", probe)
        expect { !rail.exists && abs(pane.frame.minX - originalX) < 2 }
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertTrue((probe.value as? String)?.contains("focused=true;") == true)
        XCTAssertEqual(editorIdentity(probe.value as? String), identity)
        XCTAssertTrue(editor.exists)
        XCTAssertTrue(pane.exists)
        app.dismissWorkspaceKeyboard(pane: pane, editor: editor)
        XCTAssertEqual(editorIdentity(probe.value as? String), identity)
        XCTAssertTrue((editor.value as? String)?.contains("focused tap close") == true)
    }

    @MainActor
    func testLandscapeRailPreservesTheInnerTimelineAndEditorWidths() {
        assertLandscapeRail(orientation: .landscapeLeft)
    }

    @MainActor
    func testOppositeLandscapeRailPreservesTheInnerTimelineAndEditorWidths() {
        assertLandscapeRail(orientation: .landscapeRight)
    }

    @MainActor
    private func assertLandscapeRail(orientation: UIDeviceOrientation) {
        let app = launch()
        XCUIDevice.shared.orientation = orientation
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
        expect { (probe.value as? String)?.contains(";sidebarCanOpen=true;") == true }
        // The failure recording places the former mid-edge point in the
        // landscape sensor corridor. Start on the unobstructed screen edge.
        app.dragWorkspaceSidebarEdge(at: 0.25)
        let rail = app.descendants(matching: .any)["sidebar-rail"]
        receipt("landscape-open", probe)
        XCTAssertTrue(rail.waitForExistence(timeout: 5))
        XCTAssertEqual(pane.frame.width, paneWidth, accuracy: 2)
        XCTAssertEqual(timelineContainerWidth(probe.value as? String) ?? 0, timelineWidth, accuracy: 2)
        XCTAssertEqual(editor.frame.width, editorWidth, accuracy: 2)
        XCTAssertEqual(editorIdentity(probe.value as? String), identity)
        pane.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        receipt("landscape-close", probe)
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
        expect { (probe.value as? String)?.contains(";sidebarCanOpen=true;") == true }
        app.dragWorkspaceSidebarEdge(at: 0.3)
        let rail = app.descendants(matching: .any)["sidebar-rail"]
        receipt("editing-open", probe)
        XCTAssertTrue(rail.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertEqual(pane.frame.width, before.width, accuracy: 2)
        XCTAssertEqual(editorIdentity(probe.value as? String), identity)
        XCTAssertTrue((probe.value as? String)?.contains("focused=true;") == true)
        let closeStart = pane.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        closeStart.press(forDuration: 0.05, thenDragTo: closeStart.withOffset(CGVector(dx: -110, dy: 0)))
        receipt("editing-reverse-close", probe)
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
        let probe = app.descendants(matching: .any)["surface-native-interaction-probe"]
        expect { (probe.value as? String)?.contains(";sidebarCanOpen=true;") == true }
        app.dragWorkspaceSidebarEdge(at: 0.5)
        let rail = app.descendants(matching: .any)["sidebar-rail"]
        receipt("resting-open", probe)
        XCTAssertTrue(rail.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["sidebar-search"].exists)
        XCTAssertTrue(app.buttons["sidebar-files"].exists)
        XCTAssertTrue(app.buttons["sidebar-settings"].exists)
        XCTAssertGreaterThan(pane.frame.minX, before.minX + 30)
        XCTAssertEqual(pane.frame.width, before.width, accuracy: 2)
        XCTAssertFalse(app.buttons["sidebar-open"].exists)
        pane.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.3)).tap()
        receipt("resting-close", probe)
        expect { !rail.exists }
        XCTAssertEqual(pane.frame.minX, before.minX, accuracy: 2)
        XCTAssertTrue((editor.value as? String)?.contains("retained sidebar draft") == true)
    }

    @MainActor
    func testInteriorSwipeIsIgnoredButStableSplitCanRevealRail() {
        let app = launch()
        let interior = app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        interior.press(forDuration: 0.05, thenDragTo: interior.withOffset(CGVector(dx: 110, dy: 0)))
        XCTAssertFalse(app.descendants(matching: .any)["sidebar-rail"].exists)
        app.openWorkspaceSidebar()
        app.buttons["split-entry"].tap()
        app.buttons["split-open-top"].tap()
        let picker = app.descendants(matching: .any)["split-empty-pane-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        app.dragWorkspaceSidebarEdge(at: 0.35)
        XCTAssertTrue(app.descendants(matching: .any)["sidebar-rail"].waitForExistence(timeout: 5))
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
        app.dragWorkspaceSidebarEdge(at: 0.5)
        XCTAssertFalse(app.descendants(matching: .any)["sidebar-rail"].exists)
        XCTAssertTrue(card.exists)
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 0)
    }

    @MainActor
    private func receipt(_ label: String, _ probe: XCUIElement) {
        let value = probe.value as? String ?? "missing"
        let begin = value.range(of: ";sidebar=")?.upperBound ?? value.startIndex
        let end = value.range(of: ";timeline=", range: begin..<value.endIndex)?.lowerBound ?? value.endIndex
        print("SIDEBAR_RECEIPT \(label) \(value[begin..<end])")
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launch()
        XCTAssertTrue(app.textViews["conversation-composer-input"].waitForExistence(timeout: 15))
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

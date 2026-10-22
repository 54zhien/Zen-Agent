import XCTest
import UIKit

final class SidebarUITests: XCTestCase {
    @MainActor
    func testRaisedSheetConsumesFirstEdgeSwipeAndNextSwipeOpensSidebar() {
        let app = launch(withKeyboardMenu: true)
        let editor = app.textViews["conversation-composer-input"]
        let probe = app.descendants(matching: .any)["surface-native-interaction-probe"]
        editor.tap()
        editor.typeText("sheet Sidebar draft")
        expect { app.keyboards.firstMatch.exists
            && (probe.value as? String)?.contains("focused=true;") == true }
        let identity = editorIdentity(probe.value as? String)
        XCTAssertNotNil(identity)
        app.buttons["conversation-composer-plus"].tap()
        let sheet = app.descendants(matching: .any)["composer-keyboard-sheet"]
        // UIKit can expose a replacement inputView inside Keyboard's AX
        // container; the actual sheet and menu row identify this presentation.
        expect { sheet.exists && app.buttons["模型"].exists }

        app.dismissWorkspaceInputForSidebar()
        XCTAssertFalse(app.descendants(matching: .any)["sidebar-rail"].exists)
        XCTAssertFalse(sheet.exists)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertEqual(editorIdentity(probe.value as? String), identity)
        app.openWorkspaceSidebar()
        XCTAssertTrue(app.buttons["sidebar-settings"].isHittable)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertEqual(editorIdentity(probe.value as? String), identity)
        XCTAssertEqual(editor.value as? String, "sheet Sidebar draft")
    }

    @MainActor
    func testSidebarSettingsCoordinateRoutePreservesAXFailure() {
        _ = exerciseSidebarSettingsRoute(launch(), omitsFullSurfaceRole: false)
    }

    @MainActor
    func testSidebarSettingsWithoutFullSurfaceButtonRole() {
        let app = launch(omitFullSurfaceRole: true)
        guard exerciseSidebarSettingsRoute(app, omitsFullSurfaceRole: true) else { return }
        app.buttons["settings-close"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings-page"].waitForNonExistence(timeout: 5))
        app.openWorkspaceSidebar()
        app.buttons["sidebar-settings"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings-page"].waitForExistence(timeout: 5))
        attachSidebarSettingsRouteEvidence(app, stage: "after-semantic-settings-tap")
    }

    @MainActor
    private func exerciseSidebarSettingsRoute(_ app: XCUIApplication, omitsFullSurfaceRole: Bool) -> Bool {
        let probe = app.descendants(matching: .any)["surface-native-interaction-probe"]
        expect { self.editorIdentity(probe.value as? String) != nil }
        let originalEditor = editorIdentity(probe.value as? String)
        app.openWorkspaceSidebar()

        let expectedRole = "surfaceRoleButton=\(!omitsFullSurfaceRole);"
        let nativeRoleMatches = (probe.value as? String)?.contains(expectedRole) == true
        XCTAssertTrue(nativeRoleMatches,
                      "The native full-page trait control must actually take effect")
        let cardButtons = app.buttons.matching(NSPredicate(format: "label == %@", "新对话，创建新对话"))
            .allElementsBoundByIndex.filter { $0.frame.width >= app.frame.width * 0.95
                && $0.frame.height >= app.frame.height * 0.95 }
        print("SIDEBAR_FULL_ROLE omitted=\(omitsFullSurfaceRole) exportedFullPageButtons=\(cardButtons.count)")
        let exportedRoleMatches = omitsFullSurfaceRole ? cardButtons.isEmpty : !cardButtons.isEmpty
        if omitsFullSurfaceRole {
            XCTAssertEqual(cardButtons.count, 0, "The anomalous full-page Button role must actually disappear")
        } else {
            XCTAssertGreaterThan(cardButtons.count, 0, "Baseline must expose the role under investigation")
        }
        XCTAssertTrue(app.scrollViews["conversation-pane-preview-ui-11"].exists)
        XCTAssertTrue(app.textViews["conversation-composer-input"].exists)
        XCTAssertEqual(editorIdentity(probe.value as? String), originalEditor)
        receipt("full-surface-role-control", probe)

        let settings = app.buttons["sidebar-settings"]
        let settingsExists = settings.waitForExistence(timeout: 5)
        XCTAssertTrue(settingsExists, "Sidebar Settings destination must exist")
        XCTAssertEqual(app.buttons.matching(identifier: "sidebar-settings").count, 1,
                       "The semantic Settings Button must remain unique")
        XCTAssertEqual(settings.label, "设置", "The semantic Button must retain its spoken name")
        let settingsHittable = settings.wait(for: \.isHittable, toEqual: true, timeout: 5)
        XCTAssertTrue(settingsHittable, "Sidebar Settings AX destination must remain hittable")

        let appFrame = app.frame
        let settingsFrame = settings.frame
        let frameCoordinates = [
            appFrame.minX, appFrame.minY, appFrame.maxX, appFrame.maxY,
            appFrame.width, appFrame.height,
            settingsFrame.minX, settingsFrame.minY, settingsFrame.maxX, settingsFrame.maxY,
            settingsFrame.width, settingsFrame.height
        ]
        let frameIsFinite = frameCoordinates.allSatisfy { $0.isFinite }
        let appFrameIsPositive = appFrame.width > 0 && appFrame.height > 0
        let settingsFrameIsPositive = settingsFrame.width > 0 && settingsFrame.height > 0
        let frameIsWithinApp = settingsFrame.minX >= appFrame.minX
            && settingsFrame.minY >= appFrame.minY
            && settingsFrame.maxX <= appFrame.maxX
            && settingsFrame.maxY <= appFrame.maxY
        let frameIsUsable = settingsExists && frameIsFinite && appFrameIsPositive
            && settingsFrameIsPositive && frameIsWithinApp
        print("SIDEBAR_SETTINGS_ROUTE before frame=\(settingsFrame) app=\(appFrame) exists=\(settingsExists) hittable=\(settingsHittable) finite=\(frameIsFinite) positive=\(settingsFrameIsPositive) withinApp=\(frameIsWithinApp)")
        attachSidebarSettingsRouteEvidence(app, stage: "before-coordinate-tap")
        XCTAssertTrue(frameIsUsable,
            "Settings AX frame must be finite, positive, and within the app: settings=\(settingsFrame), app=\(appFrame)")
        guard frameIsUsable else {
            print("SIDEBAR_SETTINGS_ROUTE after route=skipped-invalid-frame")
            return false
        }

        let center = CGPoint(x: settingsFrame.midX, y: settingsFrame.midY)
        let offset = CGVector(
            dx: (center.x - appFrame.minX) / appFrame.width,
            dy: (center.y - appFrame.minY) / appFrame.height
        )
        app.coordinate(withNormalizedOffset: offset).tap()

        let settingsPage = app.descendants(matching: .any)["settings-page"]
        let destinationAppeared = settingsPage.waitForExistence(timeout: 5)
        XCTAssertTrue(destinationAppeared,
            "The app-level Settings coordinate must open the existing Settings page")
        print("SIDEBAR_SETTINGS_ROUTE after route=app-coordinate center=\(center) page=\(destinationAppeared)")
        attachSidebarSettingsRouteEvidence(app, stage: "after-coordinate-tap")
        return nativeRoleMatches && exportedRoleMatches && settingsHittable && destinationAppeared
    }

    @MainActor
    func testBackgroundResumeKeepsTheExpandedSidebarAndRestoresClosing() {
        let app = launch()
        app.openWorkspaceSidebar()
        XCUIDevice.shared.press(.home)
        app.activate()
        let rail = app.descendants(matching: .any)["sidebar-rail"]
        XCTAssertTrue(rail.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["sidebar-settings"].wait(for: \.isEnabled, toEqual: true, timeout: 10))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.4)).tap()
        expect { !rail.exists }
    }

    @MainActor
    func testConversationControlsFormOneVerticalGroupWithoutASplitShortcut() {
        let app = launch()
        app.openWorkspaceSidebar()
        XCTAssertTrue(app.descendants(matching: .any)["sidebar-conversation-controls"].exists)
        let new = app.buttons["new-conversation-new"]
        let search = app.buttons["sidebar-search"]
        let recent = app.buttons["new-conversation-recent"]
        XCTAssertTrue(new.exists && search.exists && recent.exists)
        XCTAssertEqual(new.frame.maxY, search.frame.minY, accuracy: 1)
        XCTAssertEqual(search.frame.maxY, recent.frame.minY, accuracy: 1)
        XCTAssertEqual(new.frame.midX, search.frame.midX, accuracy: 1)
        XCTAssertEqual(search.frame.midX, recent.frame.midX, accuracy: 1)
        XCTAssertFalse(app.buttons["split-entry"].exists)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Shared vertical Sidebar glass"
        capture.lifetime = .keepAlways
        add(capture)
    }

    @MainActor
    func testOccupiedSecondaryRecentFailureIsVisibleAndRetryable() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launchEnvironment["ZEN_RECENT_SPLIT_FAILURE_UI_TEST"] = "1"
        app.launch()
        XCTAssertTrue(app.textViews["conversation-composer-input"].waitForExistence(timeout: 15))
        app.openWorkspaceSplit()
        let secondary = app.buttons["split-history-preview-ui-10"]
        XCTAssertTrue(secondary.waitForExistence(timeout: 10)); secondary.tap()
        app.activateWorkspacePane("preview-ui-10")
        let editor = app.textViews["conversation-composer-input"]
        editor.tap(); editor.typeText("B retained recent draft")
        expect { (editor.value as? String) == "B retained recent draft" }
        app.openWorkspaceSidebar()
        app.buttons["new-conversation-recent"].tap()
        let target = app.buttons["split-recent-preview-ui-9"]
        XCTAssertTrue(target.waitForExistence(timeout: 10)); target.tap()
        let retry = app.buttons["recent-conversation-open-retry"]
        let error = app.staticTexts["会话读取失败，原会话已保留。请重试打开。"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10), "Occupied secondary Recent must expose the failed target retry")
        XCTAssertTrue(error.exists)
        XCTAssertTrue(error.isHittable, "Open feedback must be visible even above a long Recent list")
        XCTAssertTrue(retry.isHittable)
        guard retry.exists && retry.isHittable else { return }
        retry.tap()
        expect { app.scrollViews["conversation-pane-preview-ui-9"].exists && !retry.exists && !target.exists && !error.exists }
        XCTAssertTrue(app.scrollViews["conversation-pane-preview-ui-11"].exists)
    }
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
        app.openWorkspaceSplit()
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
    func testShiftedBlankTapClosesRailWithoutRestoringTheDismissedKeyboard() {
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
        app.openWorkspaceSidebar()
        let rail = app.descendants(matching: .any)["sidebar-rail"]
        receipt("focused-open", probe)
        XCTAssertTrue(rail.waitForExistence(timeout: 5))
        expect { !app.keyboards.firstMatch.exists
            && (probe.value as? String)?.contains("focused=false;") == true }
        guard let blank = app.workspaceTimelineBlankPoint(pane: pane, editor: editor, preferLeading: true) else { return }
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: blank.x, dy: blank.y)).tap()
        receipt("focused-close", probe)
        expect { !rail.exists && abs(pane.frame.minX - originalX) < 2 }
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertTrue((probe.value as? String)?.contains("focused=false;") == true)
        XCTAssertEqual(editorIdentity(probe.value as? String), identity)
        XCTAssertTrue(editor.exists)
        XCTAssertTrue(pane.exists)
        editor.tap()
        expect { app.keyboards.firstMatch.exists
            && (probe.value as? String)?.contains("focused=true;") == true }
        receipt("focused-reopen", probe)
        app.dismissWorkspaceKeyboard(pane: pane, editor: editor)
        XCTAssertEqual(editorIdentity(probe.value as? String), identity)
        XCTAssertTrue((editor.value as? String)?.contains("focused tap close") == true)
        // Reusing the same native input after Sidebar closure must also retain
        // its Lift recognizer and become eligible for the production Split drag.
        app.openWorkspaceSplit()
        XCTAssertTrue(app.descendants(matching: .any)["split-empty-pane-picker"].exists)
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
    func testStableEditingSidebarDismissesKeyboardWithoutChangingNativeOwner() {
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
        app.openWorkspaceSidebar()
        let rail = app.descendants(matching: .any)["sidebar-rail"]
        receipt("editing-open", probe)
        XCTAssertTrue(rail.waitForExistence(timeout: 5))
        expect { !app.keyboards.firstMatch.exists
            && (probe.value as? String)?.contains("focused=false;") == true }
        XCTAssertEqual(pane.frame.width, before.width, accuracy: 2)
        XCTAssertEqual(editorIdentity(probe.value as? String), identity)
        XCTAssertTrue((probe.value as? String)?.contains("focused=false;") == true)
        let closeStart = pane.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        closeStart.press(forDuration: 0.05, thenDragTo: closeStart.withOffset(CGVector(dx: -110, dy: 0)))
        receipt("editing-reverse-close", probe)
        expect { !rail.exists }
        XCTAssertEqual(pane.frame.minX, before.minX, accuracy: 2)
        XCTAssertEqual(editorIdentity(probe.value as? String), identity)
        XCTAssertTrue((editor.value as? String)?.contains("editing sidebar draft") == true)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertTrue((probe.value as? String)?.contains("focused=false;") == true)
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
        app.openWorkspaceSplit()
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
        let keys = ["focused", "editorFrame", "point", "hit", "presentationState", "composerMotionPhase",
                    "workspaceInputSuppressed", "editorCanFocus", "dockEvents"]
        let fields = value.components(separatedBy: ";").filter { item in
            keys.contains { item.hasPrefix($0 + "=") }
        }
        print("SIDEBAR_INPUT \(label) \(fields.joined(separator: ";"))")
        let attachment = XCTAttachment(string: value)
        attachment.name = "Native Sidebar \(label)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func launch(withKeyboardMenu: Bool = false, omitFullSurfaceRole: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        if omitFullSurfaceRole { app.launchEnvironment["ZEN_SIDEBAR_AX_OMIT_FULL_ROLE"] = "1" }
        if withKeyboardMenu { app.launchEnvironment["ZEN_KEYBOARD_MENU_UI_TEST"] = "1" }
        app.launch()
        XCTAssertTrue(app.textViews["conversation-composer-input"].waitForExistence(timeout: 15))
        return app
    }

    private func editorIdentity(_ diagnostic: String?) -> String? {
        diagnostic?.split(separator: ";").first { $0.hasPrefix("editorIdentity=") }.map(String.init)
    }

    @MainActor
    private func attachSidebarSettingsRouteEvidence(_ app: XCUIApplication, stage: String) {
        XCTContext.runActivity(named: "Sidebar Settings route \(stage)") { activity in
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Sidebar Settings \(stage) screenshot"
            screenshot.lifetime = .keepAlways
            activity.add(screenshot)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Sidebar Settings \(stage) full AX hierarchy"
            hierarchy.lifetime = .keepAlways
            activity.add(hierarchy)
        }
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

import XCTest

final class SplitContainerUITests: XCTestCase {
    @MainActor
    func testSharedComposerKeepsFocusWhenTappingOppositeMessageBody() {
        let app = launchedOccupiedSplit(observeContentFocus: true)
        let input = app.textViews["conversation-composer-input"]
        input.tap()
        input.typeText("secondary content-tap draft")
        let source = app.scrollViews.matching(identifier: "conversation-pane-preview-ui-11").firstMatch
        let sourceProbe = app.descendants(matching: .any)["surface-native-interaction-probe"]
        let secondaryProbe = app.descendants(matching: .any)["split-secondary-native-interaction-probe"]

        // The existing switch regression taps the Timeline margin. Hit an
        // actual selectable message instead: its native text interactions can
        // participate in responder arbitration before the Pane tap ends.
        func tapVisibleMessage() -> Bool {
            let messages = source.descendants(matching: .any).matching(NSPredicate(
                format: "value BEGINSWITH %@ OR label BEGINSWITH %@",
                "Assistant response", "Assistant response"))
            guard let message = messages.allElementsBoundByIndex.first(where: {
                $0.isHittable && $0.frame.height > 0 && source.frame.intersects($0.frame)
            }) else {
                XCTFail("Expected a visible seeded message body without scrolling or refocusing")
                return false
            }
            print("SPLIT_BODY_TARGET type=\(message.elementType.rawValue);frame=\(message.frame);value=\(String(describing: message.value))")
            message.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5)).tap()
            recordNativeSurfaces(app, stage: "after opposite message body tap")
            return true
        }

        guard app.keyboards.firstMatch.exists else {
            XCTFail("Expected the keyboard to be open before the content tap")
            return
        }
        guard tapVisibleMessage() else { return }
        expect { (input.value as? String) != "secondary content-tap draft" }
        guard app.keyboards.firstMatch.exists,
              (sourceProbe.value as? String)?.contains("focused=true;") == true else {
            XCTFail("Opposite message-body tap must transfer focus without another editor tap: \(sourceProbe.value ?? "missing probe")")
            return
        }
        input.typeText("source content-tap draft")
        app.activateWorkspacePane("preview-ui-10")
        expect { (input.value as? String) == "secondary content-tap draft" }
        guard app.keyboards.firstMatch.exists,
              (secondaryProbe.value as? String)?.contains("focused=true;") == true else {
            XCTFail("Blank-margin control must preserve focus: \(secondaryProbe.value ?? "missing probe")")
            return
        }
        guard tapVisibleMessage() else { return }
        expect { (input.value as? String) == "source content-tap draft" }
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertTrue((sourceProbe.value as? String)?.contains("focused=true;") == true,
                      "Repeated content switching must retain focus: \(sourceProbe.value ?? "missing probe")")
    }

    @MainActor
    func testMessageBodyLongPressStillSelectsAndDragsAQuote() {
        let app = launchedOccupiedSplit(observeContentFocus: true)
        let input = app.textViews["conversation-composer-input"]
        input.tap()
        input.typeText("quote destination draft")
        let source = app.scrollViews.matching(identifier: "conversation-pane-preview-ui-11").firstMatch
        let messages = source.textViews.matching(NSPredicate(
            format: "value BEGINSWITH %@", "Assistant response"))
        guard let message = messages.allElementsBoundByIndex.first(where: {
            $0.isHittable && $0.frame.height > 0 && source.frame.intersects($0.frame)
        }) else { XCTFail("Expected selectable source text"); return }
        guard let seedValue = message.value as? String else { XCTFail("Expected a unique seeded message value"); return }
        let stableMessage = messages.matching(NSPredicate(format: "value == %@", seedValue)).firstMatch
        let word = stableMessage.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5))
        word.press(forDuration: 0.8)
        let copy = app.menuItems["Copy"]
        guard copy.waitForExistence(timeout: 5) else {
            XCTFail("Long press must retain native text selection and its Copy action")
            return
        }
        XCTAssertEqual(input.value as? String, "quote destination draft",
                       "Selecting text must not replace the active input owner")
        // The first word is "Assistant". Start near its center, away from
        // the leading selection handle that UIKit treats as range adjustment.
        let selectedWordCenter = stableMessage.coordinate(withNormalizedOffset: CGVector(dx: 0.21, dy: 0.5))
        selectedWordCenter.press(forDuration: 0.8, thenDragTo: input.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        XCTAssertTrue(app.buttons["移除引用"].waitForExistence(timeout: 5),
                      "The native selected range must still produce a Quote drop")
        XCTAssertEqual(input.value as? String, "quote destination draft")
    }

    @MainActor
    func testMessageBodyDoubleTapStillSelectsText() {
        let app = launchedOccupiedSplit(observeContentFocus: true)
        app.activateWorkspacePane("preview-ui-11")
        let input = app.textViews["conversation-composer-input"]
        input.tap()
        input.typeText("double tap destination draft")
        let source = app.scrollViews.matching(identifier: "conversation-pane-preview-ui-11").firstMatch
        let messages = source.textViews.matching(NSPredicate(
            format: "value BEGINSWITH %@", "Assistant response"))
        guard let message = messages.allElementsBoundByIndex.first(where: {
            $0.isHittable && $0.frame.height > 0 && source.frame.intersects($0.frame)
        }) else { XCTFail("Expected selectable source text"); return }
        guard let seedValue = message.value as? String else { XCTFail("Expected a unique seeded message value"); return }
        let stableMessage = messages.matching(NSPredicate(format: "value == %@", seedValue)).firstMatch
        stableMessage.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5)).doubleTap()
        XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 5),
                      "Double tap must retain native word selection and its Copy action")
        XCTAssertEqual(input.value as? String, "double tap destination draft",
                       "Word selection must preserve this Pane's draft")

        // Re-enter the Composer after a native selection, then activate that
        // same body. A retained range must not turn a Pane tap into focus loss.
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        stableMessage.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5)).tap()
        let probe = app.descendants(matching: .any)["surface-native-interaction-probe"]
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertTrue((probe.value as? String)?.contains("focused=true;") == true)
        stableMessage.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5)).doubleTap()
        XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 5),
                      "Selection must remain available after returning from the Composer")
    }

    @MainActor
    func testPromptTapKeepsComposerFocusAndDoubleTapStillSelectsText() {
        let app = launchedOccupiedSplit(observeContentFocus: true)
        let input = app.textViews["conversation-composer-input"]
        input.tap()
        input.typeText("prompt destination draft")
        let source = app.scrollViews.matching(identifier: "conversation-pane-preview-ui-11").firstMatch
        let prompts = source.textViews.matching(NSPredicate(
            format: "value BEGINSWITH %@", "User prompt"))
        guard let prompt = prompts.allElementsBoundByIndex.first(where: {
            $0.isHittable && $0.frame.height > 0 && source.frame.intersects($0.frame)
        }) else { XCTFail("Expected a visible Prompt capsule"); return }
        guard let seedValue = prompt.value as? String else { XCTFail("Expected a unique seeded message value"); return }
        let stablePrompt = prompts.matching(NSPredicate(format: "value == %@", seedValue)).firstMatch
        let word = stablePrompt.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5))
        word.tap()
        let probe = app.descendants(matching: .any)["surface-native-interaction-probe"]
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertTrue((probe.value as? String)?.contains("focused=true;") == true)
        input.typeText("source prompt draft")
        word.doubleTap()
        XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 5),
                      "Prompt text must retain native word selection")
        XCTAssertEqual(input.value as? String, "source prompt draft")
    }

    @MainActor
    func testActivePromptDoubleTapPresentsNativeCopyMenu() {
        let app = launchedOccupiedSplit(observeContentFocus: true)
        app.activateWorkspacePane("preview-ui-11")
        let input = app.textViews["conversation-composer-input"]
        input.tap()
        input.typeText("active prompt selection draft")
        let source = app.scrollViews.matching(identifier: "conversation-pane-preview-ui-11").firstMatch
        let prompts = source.textViews.matching(NSPredicate(
            format: "value BEGINSWITH %@", "User prompt"))
        guard let prompt = prompts.allElementsBoundByIndex.first(where: {
            $0.isHittable && $0.frame.height > 0 && source.frame.intersects($0.frame)
        }), let seedValue = prompt.value as? String else {
            XCTFail("Expected a visible seeded Prompt capsule"); return
        }
        let stablePrompt = prompts.matching(NSPredicate(format: "value == %@", seedValue)).firstMatch
        stablePrompt.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5)).doubleTap()
        XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 5),
                      "Double tapping the active Prompt must preserve native Copy")
        XCTAssertEqual(input.value as? String, "active prompt selection draft")
    }

    @MainActor
    func testActivePaneBlankTapStillDismissesTheKeyboard() {
        let app = launchedOccupiedSplit()
        let input = app.textViews["conversation-composer-input"]
        input.tap()
        input.typeText("explicit blur draft")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        app.activateWorkspacePane("preview-ui-10")
        expect { !app.keyboards.firstMatch.exists }
        XCTAssertEqual(input.value as? String, "explicit blur draft")
        let probe = app.descendants(matching: .any)["split-secondary-native-interaction-probe"]
        XCTAssertTrue((probe.value as? String)?.contains("focused=false;") == true)
    }

    @MainActor
    func testSharedBottomComposerFollowsContentTapWithoutSharingDrafts() {
        let app = launchedOccupiedSplit()
        let input = app.textViews["conversation-composer-input"]
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 1)
        XCTAssertFalse(app.buttons["new-conversation-new"].exists)
        XCTAssertFalse(app.buttons["split-entry"].exists)
        let divider = app.descendants(matching: .any)["split-divider"]
        XCTAssertGreaterThan(input.frame.minY, divider.frame.maxY)
        app.activateWorkspacePane("preview-ui-11")
        input.tap(); input.typeText("upper draft stays upper")
        app.activateWorkspacePane("preview-ui-10")
        expect { !(input.value as? String ?? "").contains("upper draft stays upper") }
        let secondaryProbe = app.descendants(matching: .any)["split-secondary-native-interaction-probe"]
        guard app.keyboards.firstMatch.exists,
              (secondaryProbe.value as? String)?.contains("focused=true;") == true else {
            XCTFail("Switching Pane must retain input focus without another editor tap: \(secondaryProbe.value ?? "missing probe")")
            return
        }
        input.typeText("lower draft stays lower")
        app.activateWorkspacePane("preview-ui-11")
        expect { (input.value as? String) == "upper draft stays upper" }
        let sourceProbe = app.descendants(matching: .any)["surface-native-interaction-probe"]
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertTrue((sourceProbe.value as? String)?.contains("focused=true;") == true,
                      "Returning to source must keep focus: \(sourceProbe.value ?? "missing probe")")
        app.activateWorkspacePane("preview-ui-10")
        expect { (input.value as? String) == "lower draft stays lower" }
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertTrue((secondaryProbe.value as? String)?.contains("focused=true;") == true,
                      "Returning to secondary must keep focus: \(secondaryProbe.value ?? "missing probe")")
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 1)
        XCTAssertGreaterThan(input.frame.minY, divider.frame.maxY)
    }

    @MainActor
    func testSecondaryLiftSurvivesDeletingTheOppositePaneAndReturnsToEditableSingle() {
        // The system's default interruption handler waits out notification
        // banners, which can consume the real ten-second Undo window.
        let monitor = addUIInterruptionMonitor(withDescription: "Dismiss simulator notification banner") { banner in
            guard banner.identifier == "NotificationShortLookView" else { return false }
            banner.swipeUp()
            return !banner.exists
        }
        defer { removeUIInterruptionMonitor(monitor) }
        let app = launchedOccupiedSplit()
        let editor = app.textViews.matching(identifier: "conversation-composer-input").element(boundBy: 0)
        let start = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.7, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -220)))
        let card = app.descendants(matching: .any)["workspace-current-card"]
        expect { card.exists && card.label.contains("Workspace conversation 10") }
        card.swipeLeft()
        expect { card.label.contains("Workspace conversation 11") }
        card.swipeUp()
        expect { card.exists && card.label.contains("Workspace conversation 10") }
        card.tap()
        expect { (app.otherElements["split-secondary-lift-state-probe"].value as? String) == "full" }
        expect { app.textViews.matching(identifier: "conversation-composer-input").count == 1 }
        XCTAssertFalse(app.descendants(matching: .any)["split-divider"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["conversation-pane-preview-ui-10"].exists)
        let survivor = app.textViews["conversation-composer-input"]
        let undo = app.buttons["workspace-card-undo-preview-ui-11"]
        XCTAssertTrue(undo.exists)
        XCTAssertLessThan(undo.frame.maxY, survivor.frame.minY,
                          "Full must retain Undo above the live Composer")
        recordNativeSurfaces(app, stage: "Single before editor tap")
        survivor.tap()
        recordNativeSurfaces(app, stage: "Single after editor tap")
        survivor.typeText("surviving secondary draft")
        XCTAssertTrue((survivor.value as? String)?.contains("surviving secondary draft") == true)
    }

    @MainActor
    func testAppSpaceCardMenuOpensSelectedConversationInSplit() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launch()
        let editor = app.textViews["conversation-composer-input"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        let start = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.7, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -220)))
        let menu = app.buttons["workspace-card-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        let split = app.buttons["分屏打开"]
        guard split.waitForExistence(timeout: 5) else {
            XCTFail("The selected Conversation card needs an Open in Split action")
            return
        }
        split.tap()
        XCTAssertTrue(app.otherElements["split-empty-pane-picker"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["conversation-pane-preview-ui-11"].exists)
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 1)
    }

    @MainActor
    func testSourceSplitPaneLiftsToAppSpaceAndReturnsWithOtherPaneIntact() {
        let app = launchedOccupiedSplit(usingDrag: true)
        app.activateWorkspacePane("preview-ui-11")
        let editor = app.textViews.matching(identifier: "conversation-composer-input").element(boundBy: 0)
        XCTAssertTrue(editor.exists)
        let start = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.7, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -220)))
        expect { (app.otherElements["surface-lift-state-probe"].value as? String) == "card" }
        recordNativeSurfaces(app, stage: "source lifted")
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 0)
        app.descendants(matching: .any)["workspace-current-card"].tap()
        expect { (app.otherElements["surface-lift-state-probe"].value as? String) == "full" }
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 1)
        XCTAssertTrue(app.descendants(matching: .any)["conversation-pane-preview-ui-10"].exists)
    }

    @MainActor
    func testSecondarySplitPaneLiftsToAppSpaceAndReturnsWithSourceIntact() {
        let app = launchedOccupiedSplit()
        let position = app.buttons["preview-reading-position"]
        position.tap()
        expect { (position.value as? String) == "settled" }
        let anchor = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ OR value == %@", "PREVIEW_READING_ANCHOR_10",
            "PREVIEW_READING_ANCHOR_10")).firstMatch
        XCTAssertTrue(anchor.exists && anchor.isHittable)
        let anchorFrame = anchor.frame
        // SwiftUI propagates the Pane identifier to its timeline and Composer
        // accessibility siblings. Measure the native timeline viewport explicitly.
        let sourcePane = app.scrollViews.matching(identifier: "conversation-pane-preview-ui-11").firstMatch
        let sourceHeight = sourcePane.frame.height
        let editor = app.textViews.matching(identifier: "conversation-composer-input").element(boundBy: 0)
        XCTAssertTrue(editor.exists)
        let start = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.7, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -220)))
        expect { (app.otherElements["split-secondary-lift-state-probe"].value as? String) == "card" }
        recordNativeSurfaces(app, stage: "secondary lifted")
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 0)
        app.descendants(matching: .any)["workspace-current-card"].tap()
        expect { (app.otherElements["split-secondary-lift-state-probe"].value as? String) == "full" }
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 1)
        XCTAssertTrue(app.descendants(matching: .any)["conversation-pane-preview-ui-11"].exists)
        expect { anchor.exists && anchor.isHittable && (position.value as? String) == "settled" }
        XCTAssertEqual(anchor.frame.minY, anchorFrame.minY, accuracy: 3,
                       "The hidden sibling must retain its reading position through remount")

        let nextStart = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        nextStart.press(forDuration: 0.7, thenDragTo: nextStart.withOffset(CGVector(dx: 0, dy: -220)))
        expect { (app.otherElements["split-secondary-lift-state-probe"].value as? String) == "card" }
        let queue = app.buttons["preview-hidden-reading-position"]
        XCTAssertTrue(queue.exists)
        queue.tap()
        XCTAssertEqual(queue.value as? String, "pending", "Hidden Pane cannot acknowledge a queued request")
        app.descendants(matching: .any)["workspace-current-card"].tap()
        expect { (app.otherElements["split-secondary-lift-state-probe"].value as? String) == "full" }
        let requested = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ OR value == %@", "Assistant response 12",
            "Assistant response 12")).firstMatch
        expect { requested.exists && requested.isHittable && (position.value as? String) == "settled" }
        XCTAssertLessThan(sourcePane.frame.height, sourceHeight - 30)
        let expectedY = anchorFrame.minY + (sourcePane.frame.height - sourceHeight) * 0.2
        XCTAssertEqual(requested.frame.minY, expectedY, accuracy: 3,
                       "The remounted Timeline must apply its queued anchor using the new viewport")
    }

    @MainActor
    private func recordNativeSurfaces(_ app: XCUIApplication, stage: String) {
        for id in ["surface-native-interaction-probe", "split-secondary-native-interaction-probe"] {
            print("SPLIT_NATIVE \(stage) \(id): \(String(describing: app.otherElements[id].value))")
        }
    }

    @MainActor
    private func launchedOccupiedSplit(usingDrag: Bool = false, observeContentFocus: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        if observeContentFocus {
            app.launchEnvironment["ZEN_SPLIT_CONTENT_FOCUS_DIAGNOSTIC"] = "1"
            app.launchEnvironment["ZEN_SELECTION_SCROLL_CONTROL"] = "1"
        }
        app.launch()
        if usingDrag {
            let editor = app.textViews["conversation-composer-input"]
            XCTAssertTrue(editor.waitForExistence(timeout: 15))
            let start = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.7,
                        thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.18)))
        } else {
            app.openWorkspaceSidebar()
        let entry = app.buttons["split-entry"]
            XCTAssertTrue(entry.waitForExistence(timeout: 15))
            entry.tap()
            let action = app.buttons["split-open-top"]
            XCTAssertTrue(action.waitForExistence(timeout: 10))
            action.tap()
        }
        let history = app.buttons["split-history-preview-ui-10"]
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        history.tap()
        XCTAssertTrue(app.scrollViews.matching(identifier: "conversation-pane-preview-ui-10").firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["split-secondary-pane"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func expect(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let pending = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [pending], timeout: 10), .completed, file: file, line: line)
    }

    @MainActor
    func testBottomDropPlacesTheEmptyPickerAboveTheSourcePane() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launch()
        let editor = app.textViews["conversation-composer-input"]
        guard editor.waitForExistence(timeout: 15) else {
            XCTFail("Seeded Conversation editor missing")
            return
        }
        let start = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        start.press(forDuration: 0.7,
                    thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.57)))
        let picker = app.otherElements["split-empty-pane-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        XCTAssertLessThan(picker.frame.midY, editor.frame.midY)
    }

    @MainActor
    func testAccessibleBottomSplitCreatesANewSecondConversationAndClosesWithoutDeletingIt() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launch()
        let source = app.descendants(matching: .any)["conversation-pane-preview-ui-11"]
        XCTAssertTrue(source.waitForExistence(timeout: 15))
        app.openWorkspaceSidebar()
        let entry = app.buttons["split-entry"]
        guard entry.waitForExistence(timeout: 10) else {
            XCTFail("Accessible Split menu missing")
            return
        }
        entry.tap()
        let action = app.buttons["split-open-bottom"]
        guard action.waitForExistence(timeout: 10) else {
            XCTFail("Bottom Pane action missing")
            return
        }
        action.tap()
        let picker = app.otherElements["split-empty-pane-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        let newCard = app.buttons["split-new-conversation"]
        XCTAssertTrue(newCard.waitForExistence(timeout: 10))
        newCard.tap()
        XCTAssertTrue(app.descendants(matching: .any)["split-secondary-pane"].waitForExistence(timeout: 10))
        XCTAssertTrue(source.exists)
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 1)
        let divider = app.descendants(matching: .any)["split-divider"]
        XCTAssertTrue(divider.waitForExistence(timeout: 10))
        divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.8)
        let closeTop = app.buttons["关闭上方窗格"]
        XCTAssertTrue(closeTop.waitForExistence(timeout: 5))
        closeTop.tap()
        expect { app.textViews.matching(identifier: "conversation-composer-input").count == 1 }
        XCTAssertTrue(source.exists)
        XCTAssertFalse(app.descendants(matching: .any)["split-secondary-pane"].exists)
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 1)
    }

    @MainActor
    func testPickerSelectionMountsASecondLiveConversation() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launch()
        let editor = app.textViews["conversation-composer-input"]
        guard editor.waitForExistence(timeout: 15) else {
            XCTFail("Seeded Conversation editor missing")
            return
        }
        let start = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.7,
                    thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.18)))
        let picker = app.otherElements["split-empty-pane-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        let history = app.buttons["split-history-preview-ui-10"]
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        history.tap()
        XCTAssertTrue(app.scrollViews.matching(identifier: "conversation-pane-preview-ui-10").firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["conversation-pane-preview-ui-10"]
            .waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["conversation-pane-preview-ui-11"].exists)
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 1)
    }

    @MainActor
    func testAccessibleTopSplitEntryOpensTheSameEmptyPanePicker() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launch()
        XCTAssertTrue(app.textViews["conversation-composer-input"].waitForExistence(timeout: 15))
        app.openWorkspaceSidebar()
        let entry = app.buttons["split-entry"]
        guard entry.waitForExistence(timeout: 10) else {
            XCTFail("Accessible Split menu missing")
            return
        }
        entry.tap()
        let action = app.buttons["split-open-top"]
        guard action.waitForExistence(timeout: 10) else {
            XCTFail("Top Pane action missing")
            return
        }
        action.tap()
        XCTAssertTrue(app.otherElements["split-empty-pane-picker"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testTopDropKeepsTheSourceAndOpensAnEmptySecondPane() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launch()

        let editor = app.textViews["conversation-composer-input"]
        guard editor.waitForExistence(timeout: 15) else {
            XCTFail("Seeded Conversation editor missing")
            return
        }
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        editor.typeText("Split source draft")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.25)).tap()
        let keyboardHidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !app.keyboards.firstMatch.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardHidden], timeout: 10), .completed)

        let start = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.7,
                    thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.18)))

        XCTAssertTrue(app.otherElements["split-empty-pane-picker"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 1)
        XCTAssertTrue((editor.value as? String)?.contains("Split source draft") == true)
        XCTAssertTrue(editor.isHittable)
        editor.tap()
        editor.typeText(" still editable")
        XCTAssertTrue((editor.value as? String)?.contains("still editable") == true)
    }
}

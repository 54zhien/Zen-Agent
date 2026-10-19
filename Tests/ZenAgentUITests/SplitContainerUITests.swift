import XCTest

final class SplitContainerUITests: XCTestCase {
    @MainActor
    func testSharedComposerKeepsFocusWhenTappingOppositeMessageBody() {
        let app = launchedOccupiedSplit()
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
        guard let beforeUpperBodyTap = keyboardTransitionSnapshot(in: sourceProbe.value as? String) else {
            XCTFail("Expected the native probe to expose keyboard transition evidence")
            return
        }
        XCTAssertTrue(beforeUpperBodyTap.visible, "The transition check must begin with a visible keyboard")
        XCTAssertGreaterThan(beforeUpperBodyTap.visibleHeight, 0,
                             "The transition check must begin with a nonzero keyboard frame")
        guard tapVisibleMessage() else { return }
        expect { (input.value as? String) != "secondary content-tap draft" }
        assertKeyboardRemainedVisible(since: beforeUpperBodyTap, probe: sourceProbe,
                                      transition: "lower-to-upper message-body tap")
        guard app.keyboards.firstMatch.exists,
              (sourceProbe.value as? String)?.contains("focused=true;") == true else {
            XCTFail("Opposite message-body tap must transfer focus without another editor tap: \(sourceProbe.value ?? "missing probe")")
            return
        }
        input.typeText("source content-tap draft")
        guard let beforeLowerPaneTap = keyboardTransitionSnapshot(in: sourceProbe.value as? String) else {
            XCTFail("Expected keyboard transition evidence before returning to the lower Pane")
            return
        }
        app.activateWorkspacePane("preview-ui-10")
        expect { (input.value as? String) == "secondary content-tap draft" }
        assertKeyboardRemainedVisible(since: beforeLowerPaneTap, probe: sourceProbe,
                                      transition: "upper-to-lower Pane tap")
        guard app.keyboards.firstMatch.exists,
              (secondaryProbe.value as? String)?.contains("focused=true;") == true else {
            XCTFail("Blank-margin control must preserve focus: \(secondaryProbe.value ?? "missing probe")")
            return
        }
        guard let beforeSecondUpperBodyTap = keyboardTransitionSnapshot(in: sourceProbe.value as? String) else {
            XCTFail("Expected keyboard transition evidence before the second upper message-body tap")
            return
        }
        guard tapVisibleMessage() else { return }
        expect { (input.value as? String) == "source content-tap draft" }
        assertKeyboardRemainedVisible(since: beforeSecondUpperBodyTap, probe: sourceProbe,
                                      transition: "lower-to-upper repeated message-body tap")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertTrue((sourceProbe.value as? String)?.contains("focused=true;") == true,
                      "Repeated content switching must retain focus: \(sourceProbe.value ?? "missing probe")")
    }

    @MainActor
    func testMessageBodyLongPressStillSelectsAndDragsAQuote() {
        let app = launchedOccupiedSplit()
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
        let app = launchedOccupiedSplit()
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
        assertTimelineConvergedToBottom(app)

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
        assertTimelineConvergedToBottom(app)
    }

    @MainActor
    func testPromptTapKeepsComposerFocusAndDoubleTapStillSelectsText() {
        let app = launchedOccupiedSplit()
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
        assertTimelineConvergedToBottom(app)
    }

    @MainActor
    func testActivePromptDoubleTapPresentsNativeCopyMenu() {
        let monitor = monitorSimulatorNotificationBanner()
        defer { removeUIInterruptionMonitor(monitor) }
        let app = launchedOccupiedSplit()
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
        assertTimelineConvergedToBottom(app)
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
        let monitor = monitorSimulatorNotificationBanner()
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
        XCTAssertTrue(app.descendants(matching: .any)["split-empty-pane-picker"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["conversation-pane-preview-ui-11"].exists)
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 1)
    }

    @MainActor
    func testDividerResizesAfterAppSpaceReturn() {
        for (conversation, occupied) in [("preview-ui-11", false), ("preview-ui-11", true), ("preview-ui-10", true)] {
            let app: XCUIApplication
            if occupied { app = launchedOccupiedSplit() }
            else {
                app = XCUIApplication()
                app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
                app.launch()
                app.openWorkspaceSplit()
            }
            app.activateWorkspacePane(conversation)
            let divider = app.descendants(matching: .any)["split-divider"]
            XCTAssertTrue(divider.waitForExistence(timeout: 10))
            let originalY = divider.frame.midY
            let input = app.textViews["conversation-composer-input"]
            let start = input.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.7, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -220)))
            let phase = app.otherElements[conversation == "preview-ui-11"
                ? "surface-lift-state-probe" : "split-secondary-lift-state-probe"]
            expect { phase.value as? String == "card" }
            app.descendants(matching: .any)["workspace-current-card"].tap()
            expect { phase.value as? String == "full" }
            XCTAssertEqual(divider.frame.midY, originalY, accuracy: 1,
                "Return must retain the Split ratio before the first resize")
            recordNativeSurfaces(app, stage: "Divider Return \(conversation) occupied=\(occupied)")
            let handle = app.descendants(matching: .any)["split-divider-handle"]
            let down = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            down.press(forDuration: 0.15, thenDragTo: down.withOffset(CGVector(dx: 0, dy: 60)))
            expect { divider.frame.midY > originalY + 25 }
            let resizedY = divider.frame.midY
            print("DIVIDER_AFTER_RESIZE \(String(describing: handle.value))")
            let up = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            up.press(forDuration: 0.15, thenDragTo: up.withOffset(CGVector(dx: 0, dy: -45)))
            expect { divider.frame.midY < resizedY - 20 }
            XCTAssertTrue(app.scrollViews.matching(identifier: "conversation-pane-preview-ui-11").firstMatch.exists)
            if occupied {
                XCTAssertTrue(app.scrollViews.matching(identifier: "conversation-pane-preview-ui-10").firstMatch.exists)
            } else {
                XCTAssertTrue(app.descendants(matching: .any)["split-empty-pane-picker"].exists)
            }
            app.terminate()
        }
    }

    @MainActor
    func testSourceSplitPaneLiftsToAppSpaceAndReturnsWithOtherPaneIntact() {
        let app = launchedOccupiedSplit()
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
    private func monitorSimulatorNotificationBanner() -> NSObjectProtocol {
        addUIInterruptionMonitor(withDescription: "Dismiss simulator notification banner") { banner in
            guard banner.identifier == "NotificationShortLookView" else { return false }
            banner.swipeUp()
            return !banner.exists
        }
    }

    @MainActor
    private func recordNativeSurfaces(_ app: XCUIApplication, stage: String) {
        for id in ["surface-native-interaction-probe", "split-secondary-native-interaction-probe"] {
            print("SPLIT_NATIVE \(stage) \(id): \(String(describing: app.otherElements[id].value))")
        }
    }

    private struct KeyboardTransitionSnapshot {
        let willHideCount: Int
        let didHideCount: Int
        let offscreenFrameCount: Int
        let visibleToHiddenCount: Int
        let visible: Bool
        let visibleHeight: Int
    }

    private func keyboardTransitionSnapshot(in value: String?) -> KeyboardTransitionSnapshot? {
        guard let value else { return nil }
        let fields = Dictionary(value.split(separator: ";").compactMap { field -> (String, String)? in
            let pair = field.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { return nil }
            return (String(pair[0]), String(pair[1]))
        }, uniquingKeysWith: { _, latest in latest })
        guard let willHide = fields["keyboardTraceWillHide"].flatMap(Int.init),
              let didHide = fields["keyboardTraceDidHide"].flatMap(Int.init),
              let offscreenFrames = fields["keyboardTraceOffscreenFrames"].flatMap(Int.init),
              let visibleToHidden = fields["keyboardTraceVisibleToHidden"].flatMap(Int.init),
              let visibleText = fields["keyboardTraceVisible"],
              visibleText == "true" || visibleText == "false",
              let visibleHeight = fields["keyboardTraceVisibleHeight"].flatMap(Int.init) else { return nil }
        return KeyboardTransitionSnapshot(willHideCount: willHide, didHideCount: didHide,
            offscreenFrameCount: offscreenFrames, visibleToHiddenCount: visibleToHidden,
            visible: visibleText == "true", visibleHeight: visibleHeight)
    }

    @MainActor
    private func assertKeyboardRemainedVisible(since before: KeyboardTransitionSnapshot,
                                               probe: XCUIElement,
                                               transition: String,
                                               file: StaticString = #filePath,
                                               line: UInt = #line) {
        guard let after = keyboardTransitionSnapshot(in: probe.value as? String) else {
            XCTFail("Missing keyboard transition evidence after \(transition)", file: file, line: line)
            return
        }
        XCTAssertEqual(after.willHideCount, before.willHideCount,
                       "\(transition) must not request keyboard dismissal", file: file, line: line)
        XCTAssertEqual(after.didHideCount, before.didHideCount,
                       "\(transition) must not hide the keyboard", file: file, line: line)
        XCTAssertEqual(after.offscreenFrameCount, before.offscreenFrameCount,
                       "\(transition) must not move the keyboard offscreen", file: file, line: line)
        XCTAssertEqual(after.visibleToHiddenCount, before.visibleToHiddenCount,
                       "\(transition) must not transition the keyboard from visible to hidden", file: file, line: line)
        XCTAssertTrue(after.visible, "The keyboard must still be visible after \(transition)", file: file, line: line)
        XCTAssertGreaterThan(after.visibleHeight, 0,
                             "The keyboard frame must remain visible after \(transition)", file: file, line: line)
    }

    @MainActor
    private func assertTimelineConvergedToBottom(_ app: XCUIApplication,
                                                 file: StaticString = #filePath,
                                                 line: UInt = #line) {
        let probe = app.descendants(matching: .any)["surface-native-interaction-probe"]
        let copy = app.menuItems["Copy"]
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard copy.exists,
                  let value = probe.value as? String,
                  value.contains(";request=nil;"),
                  value.contains(";mode=followingBottom;"),
                  let metrics = self.timelineScrollMetrics(in: value) else { return false }
            return abs(metrics.offset - max(0, metrics.contentHeight - metrics.viewport)) <= 0.5
        }, object: nil)
        let result = XCTWaiter.wait(for: [settled], timeout: 10)
        XCTAssertEqual(result, .completed,
                       "The Copy menu must remain available while the native Timeline acknowledges its measured bottom: \(probe.value ?? "missing probe")",
                       file: file, line: line)
        XCTAssertTrue(copy.exists, "The native Copy menu must remain available through the scroll wait",
                      file: file, line: line)
        guard result == .completed,
              let value = probe.value as? String,
              let metrics = timelineScrollMetrics(in: value) else { return }
        XCTAssertTrue(value.contains(";request=nil;"), file: file, line: line)
        XCTAssertTrue(value.contains(";mode=followingBottom;"), file: file, line: line)
        XCTAssertLessThanOrEqual(abs(metrics.offset - max(0, metrics.contentHeight - metrics.viewport)), 0.5,
                                 "The latest native geometry must be at bottom: \(value)",
                                 file: file, line: line)
        XCTAssertTrue(copy.exists, "The native Copy menu must remain available through scroll acknowledgement",
                      file: file, line: line)
    }

    private func timelineScrollMetrics(in value: String) -> (viewport: Double, contentHeight: Double, offset: Double)? {
        guard let viewport = diagnosticNumber(after: ";ready=true;viewport=", in: value),
              let contentSize = value.range(of: "content=("),
              let contentHeight = diagnosticNumber(after: ", ", in: String(value[contentSize.upperBound...])),
              let offset = diagnosticNumber(after: ";offset=Optional(", in: value) else { return nil }
        return (viewport, contentHeight, offset)
    }

    private func diagnosticNumber(after marker: String, in value: String) -> Double? {
        guard let markerRange = value.range(of: marker) else { return nil }
        let suffix = value[markerRange.upperBound...]
        return Double(String(suffix.prefix { "0123456789.+-".contains($0) }))
    }

    @MainActor
    private func launchedOccupiedSplit() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launch()
        app.openWorkspaceSplit()
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
    func testOrdinaryLiftTowardTheLowerCenterOpensCardsBeforeSplit() {
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
                    thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)))
        let card = app.descendants(matching: .any)["workspace-current-card"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertTrue(card.label.contains("Workspace conversation 11"))
        let picker = app.descendants(matching: .any)["split-empty-pane-picker"]
        XCTAssertFalse(picker.exists)
        XCTAssertFalse(app.descendants(matching: .any)["split-secondary-pane"].exists)
    }

    @MainActor
    func testBottomSourcePickerCreatesANewSecondConversationAndClosesWithoutDeletingIt() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launchEnvironment["ZEN_BOTTOM_SOURCE_SPLIT_UI_TEST"] = "1"
        app.launch()
        let source = app.descendants(matching: .any)["conversation-pane-preview-ui-11"]
        XCTAssertTrue(source.waitForExistence(timeout: 15))
        app.openWorkspaceSplit(sourceInTopPane: false)
        let picker = app.descendants(matching: .any)["split-empty-pane-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        let sourceEditor = app.textViews["conversation-composer-input"]
        XCTAssertTrue(sourceEditor.exists)
        XCTAssertLessThan(picker.frame.midY, sourceEditor.frame.midY)
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
                    thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)))
        let picker = app.descendants(matching: .any)["split-empty-pane-picker"]
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
    func testComposerTopSplitEntryOpensTheSameEmptyPanePicker() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launch()
        XCTAssertTrue(app.textViews["conversation-composer-input"].waitForExistence(timeout: 15))
        app.openWorkspaceSplit()
        XCTAssertTrue(app.descendants(matching: .any)["split-empty-pane-picker"].waitForExistence(timeout: 10))
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
                    thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)))

        XCTAssertTrue(app.descendants(matching: .any)["split-empty-pane-picker"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 1)
        XCTAssertTrue((editor.value as? String)?.contains("Split source draft") == true)
        XCTAssertTrue(editor.isHittable)
        editor.tap()
        editor.typeText(" still editable")
        XCTAssertTrue((editor.value as? String)?.contains("still editable") == true)
    }
}

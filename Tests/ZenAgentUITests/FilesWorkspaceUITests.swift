import XCTest

final class FilesWorkspaceUITests: XCTestCase {
    @MainActor
    func testManagedPreviewAndExportUseTheNativePresentations() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launchEnvironment["ZEN_FILES_PREVIEW_UI_TEST"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["split-entry"].waitForExistence(timeout: 15))
        let probe = app.descendants(matching: .any)["surface-native-interaction-probe"]
        expect { (probe.value as? String)?.contains(";sidebarCanOpen=true;") == true }
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.001, dy: 0.3))
        edge.press(forDuration: 0.05, thenDragTo: edge.withOffset(CGVector(dx: 110, dy: 0)))
        let files = app.buttons["sidebar-files"]
        guard files.waitForExistence(timeout: 5),
              files.wait(for: \.isEnabled, toEqual: true, timeout: 5),
              files.wait(for: \.isHittable, toEqual: true, timeout: 5) else {
            XCTFail("Sidebar Files destination is unavailable")
            return
        }
        files.tap()
        let preview = app.buttons["files-preview-managed-preview-fixture"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        let ownerProbe = app.descendants(matching: .any)["files-native-owner-probe"]
        let originalOwner = ownerProbe.value as? String
        XCTAssertTrue(originalOwner?.contains("active=true") == true)
        preview.tap()
        let text = "Managed native preview/export fixture"
        expect {
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.exists
                || app.textViews.matching(NSPredicate(format: "value CONTAINS %@", text)).firstMatch.exists
        }
        let done = app.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "完成"])).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10), "Quick Look must present its native dismissal control")
        done.tap()
        let export = app.buttons["files-export-managed-preview-fixture"]
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        export.tap()
        let exportPicker = app.descendants(matching: .any)["files-native-export"]
        XCTAssertTrue(exportPicker.waitForExistence(timeout: 10), "Export must present the native document picker")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label IN %@", ["Save", "保存"])).firstMatch
            .waitForExistence(timeout: 5), "The actual export picker must offer saving the managed copy")
        cancelNativePicker(exportPicker, in: app)
        print("FILES_EXPORT_AFTER_CANCEL picker=\(exportPicker.exists) closeHittable=\(app.buttons["files-workspace-close"].isHittable)")
        let after = XCTAttachment(screenshot: app.screenshot())
        after.name = "Native export after Cancel"
        after.lifetime = .keepAlways
        add(after)
        expect { !exportPicker.exists }
        let workspaceClose = app.buttons["files-workspace-close"]
        XCTAssertTrue(workspaceClose.wait(for: \.isHittable, toEqual: true, timeout: 5))
        XCTAssertEqual(ownerProbe.value as? String, originalOwner,
                       "Native presentation must retain the same active Files owner")
        XCTAssertTrue(export.isEnabled && export.isHittable)
        workspaceClose.tap()
        expect { !app.descendants(matching: .any)["files-workspace"].exists }
        expect { app.textViews.matching(identifier: "conversation-composer-input").count == 1 }
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 1)
    }

    @MainActor
    func testFilesImportOpensTheSystemPickerAndCloseRestoresTheDraft() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["split-entry"].waitForExistence(timeout: 15))
        let editor = app.textViews["conversation-composer-input"]
        editor.tap()
        editor.typeText("draft retained through Files")
        let probe = app.descendants(matching: .any)["surface-native-interaction-probe"]
        expect { app.keyboards.firstMatch.exists
            && (probe.value as? String)?.contains("focused=true;") == true }
        let identity = editorIdentity(probe.value as? String)
        XCTAssertNotNil(identity)
        expect { (probe.value as? String)?.contains(";sidebarCanOpen=true;") == true }
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.001, dy: 0.3))
        edge.press(forDuration: 0.05, thenDragTo: edge.withOffset(CGVector(dx: 110, dy: 0)))
        let files = app.buttons["sidebar-files"]
        guard files.waitForExistence(timeout: 5),
              files.wait(for: \.isEnabled, toEqual: true, timeout: 5),
              files.wait(for: \.isHittable, toEqual: true, timeout: 5) else {
            XCTFail("Sidebar Files destination is unavailable")
            return
        }
        files.tap()
        let workspace = app.descendants(matching: .any)["files-workspace"]
        guard workspace.waitForExistence(timeout: 5) else {
            XCTFail("Files Workspace did not appear after opening Files")
            return
        }
        XCTAssertTrue(app.staticTexts["files-workspace-empty"].exists)
        app.buttons["files-import"].tap()
        let importPicker = app.descendants(matching: .any)["files-native-import"]
        XCTAssertTrue(importPicker.waitForExistence(timeout: 5))
        cancelNativePicker(importPicker, in: app)
        expect { !importPicker.exists }
        XCTAssertTrue(workspace.exists)
        XCTAssertTrue(app.staticTexts["files-workspace-empty"].exists,
                      "Picker cancellation must not create a catalog asset")
        app.buttons["files-workspace-close"].tap()
        expect { !workspace.exists }
        expect { (probe.value as? String)?.contains("focused=true;") == true }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(editorIdentity(probe.value as? String), identity)
        XCTAssertTrue((editor.value as? String)?.contains("draft retained through Files") == true)
        XCTAssertEqual(app.textViews.matching(identifier: "conversation-composer-input").count, 1)
        let pane = app.scrollViews.matching(identifier: "conversation-pane-preview-ui-11").firstMatch
        app.dismissWorkspaceKeyboard(pane: pane, editor: editor)
    }

    @MainActor
    private func cancelNativePicker(_ picker: XCUIElement, in app: XCUIApplication,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let labels = NSPredicate(format: "label IN %@", ["Cancel", "取消", "Close", "关闭"])
        // A remembered directory can hide Cancel behind native Browse navigation.
        // Rendered CI screenshots show that the hidden AX Other's stale frame
        // overlaps More. Never synthesize input at that non-hittable frame.
        for _ in 0..<6 {
            let buttons = picker.buttons.matching(labels).allElementsBoundByIndex
            let others = picker.otherElements.matching(labels).allElementsBoundByIndex
            if let cancel = (buttons + others).first(where: { $0.isHittable }) {
                let before = XCTAttachment(screenshot: app.screenshot())
                before.name = "Native picker visible Cancel"
                before.lifetime = .keepAlways
                add(before)
                print("FILES_NATIVE_VISIBLE_CANCEL frame=\(cancel.frame) type=\(cancel.elementType.rawValue)")
                cancel.tap()
                return
            }
            let back = picker.buttons["BackButton"]
            guard back.exists && back.isHittable else {
                XCTFail("Native picker has no hittable Cancel or Browse Back control", file: file, line: line)
                let failure = XCTAttachment(screenshot: app.screenshot())
                failure.name = "Native picker without visible cancellation"
                failure.lifetime = .keepAlways
                add(failure)
                return
            }
            print("FILES_NATIVE_BROWSE_BACK label=\(back.label) frame=\(back.frame)")
            back.tap()
        }
        XCTFail("Native picker did not reach visible cancellation within six Browse levels", file: file, line: line)
    }

    private func editorIdentity(_ diagnostic: String?) -> String? {
        diagnostic?.split(separator: ";").first { $0.hasPrefix("editorIdentity=") }.map(String.init)
    }

    @MainActor
    private func expect(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let pending = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [pending], timeout: 10), .completed, file: file, line: line)
    }
}

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
        let close = app.buttons.matching(NSPredicate(format: "label IN %@", ["Close", "关闭", "Cancel", "取消"])).firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(app.buttons["files-workspace-close"].waitForExistence(timeout: 5))
        app.buttons["files-workspace-close"].tap()
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
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
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

    private func editorIdentity(_ diagnostic: String?) -> String? {
        diagnostic?.split(separator: ";").first { $0.hasPrefix("editorIdentity=") }.map(String.init)
    }

    @MainActor
    private func expect(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let pending = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [pending], timeout: 10), .completed, file: file, line: line)
    }
}

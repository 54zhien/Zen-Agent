import XCTest
import UIKit

/// Temporary independent cold-start observations, not retries of a failed Gate.
final class SidebarColdLaunchDiagnosticsUITests: XCTestCase {
    @MainActor func testColdLaunch01() throws { try observeFirstEdge() }
    @MainActor func testColdLaunch02() throws { try observeFirstEdge() }
    @MainActor func testColdLaunch03() throws { try observeFirstEdge() }
    @MainActor func testColdLaunch04() throws { try observeFirstEdge() }
    @MainActor func testColdLaunch05() throws { try observeFirstEdge() }
    @MainActor func testColdLaunch06() throws { try observeFirstEdge() }

    @MainActor
    private func observeFirstEdge() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("This observation needs an iPad simulator")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.textViews["conversation-composer-input"].waitForExistence(timeout: 15))
        let source = app.descendants(matching: .any)["surface-native-interaction-probe"]
        // Match the original Pad prefix, including its native editor identity read.
        let initial = source.value as? String
        XCTAssertTrue(initial?.contains("editorIdentity=ObjectIdentifier(") == true)
        app.openWorkspaceSidebar()
        // Observe only after the single original action and its unchanged gate.
        print("SIDEBAR_COLD_RECEIPT test=\(name) value=\(String(describing: source.value))")
    }
}

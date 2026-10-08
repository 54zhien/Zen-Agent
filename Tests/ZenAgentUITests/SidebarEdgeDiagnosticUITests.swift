import XCTest
import UIKit

final class SidebarEdgeDiagnosticUITests: XCTestCase {
    @MainActor func testFirstEdgeLandscapeLeft() throws { try firstEdge(.landscapeLeft) }
    @MainActor func testFirstEdgeLandscapeRight() throws { try firstEdge(.landscapeRight) }

    @MainActor private func firstEdge(_ orientation: UIDeviceOrientation) throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad diagnostic") }
        XCUIDevice.shared.orientation = orientation
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launchEnvironment["ZEN_EDGE_DIAGNOSTIC"] = "1"
        app.launch()
        app.openWorkspaceSidebar()
        let probe = app.descendants(matching: .any)["surface-native-interaction-probe"]
        print("EDGE_DIAGNOSTIC orientation=\(orientation.rawValue) receipt=\(String(describing: probe.value))")
    }
}

import XCTest
import UIKit

final class SidebarEdgeDiagnosticUITests: XCTestCase {
    @MainActor func testBaselineLandscapeLeft() throws { try firstEdge(.landscapeLeft) }
    @MainActor func testBaselineLandscapeRight() throws { try firstEdge(.landscapeRight) }
    @MainActor func testScrollPriorityLandscapeLeft() throws { try firstEdge(.landscapeLeft, scrollOnly: true) }
    @MainActor func testScrollPriorityLandscapeRight() throws { try firstEdge(.landscapeRight, scrollOnly: true) }

    @MainActor private func firstEdge(_ orientation: UIDeviceOrientation, scrollOnly: Bool = false) throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad diagnostic") }
        XCUIDevice.shared.orientation = orientation
        defer { XCUIDevice.shared.orientation = .portrait }
        for attempt in 1...3 {
            let app = XCUIApplication()
            app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
            app.launchEnvironment["ZEN_EDGE_DIAGNOSTIC"] = "1"
            if scrollOnly { app.launchEnvironment["ZEN_EDGE_SCROLL_PRIORITY_ONLY"] = "1" }
            app.launch()
            defer { app.terminate() }
            app.openWorkspaceSidebar()
            let probe = app.descendants(matching: .any)["surface-native-interaction-probe"]
            print("EDGE_DIAGNOSTIC attempt=\(attempt) orientation=\(orientation.rawValue) scrollOnly=\(scrollOnly) receipt=\(String(describing: probe.value))")
        }
    }
}

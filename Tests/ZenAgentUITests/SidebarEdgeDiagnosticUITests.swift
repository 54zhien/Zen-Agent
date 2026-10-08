import XCTest
import UIKit

final class SidebarEdgeDiagnosticUITests: XCTestCase {
    @MainActor func testFirstEdgeLandscapeLeft() throws { try firstEdge(.landscapeLeft) }
    @MainActor func testFirstEdgeLandscapeRight() throws { try firstEdge(.landscapeRight) }
    @MainActor func testDelayedDeliveryDefaultDrag() throws {
        try firstEdge(.landscapeLeft, stallsDelivery: true)
    }
    @MainActor func testDelayedDeliverySlowDrag() throws {
        try firstEdge(.landscapeLeft, stallsDelivery: true, slow: true)
    }

    @MainActor private func firstEdge(_ orientation: UIDeviceOrientation,
                                     stallsDelivery: Bool = false, slow: Bool = false) throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad diagnostic") }
        XCUIDevice.shared.orientation = orientation
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launchEnvironment["ZEN_EDGE_DIAGNOSTIC"] = "1"
        if stallsDelivery { app.launchEnvironment["ZEN_EDGE_DELIVERY_STALL"] = "1" }
        app.launch()
        let probe = app.descendants(matching: .any)["surface-native-interaction-probe"]
        if slow {
            XCTAssertTrue(app.textViews["conversation-composer-input"].waitForExistence(timeout: 15))
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                (probe.value as? String)?.contains(";sidebarCanOpen=true;") == true
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.001, dy: 0.3))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.001 + 110 / app.frame.width, dy: 0.3))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)
            XCTAssertTrue(app.descendants(matching: .any)["sidebar-rail"].waitForExistence(timeout: 10))
        } else { app.openWorkspaceSidebar() }
        print("EDGE_DIAGNOSTIC orientation=\(orientation.rawValue) stalled=\(stallsDelivery) slow=\(slow) receipt=\(String(describing: probe.value))")
    }
}

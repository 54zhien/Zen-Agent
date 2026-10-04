import UIKit
import Testing
@testable import ZenAgent

@Suite("Sidebar native close admission")
@MainActor
struct WorkspaceSidebarInteractionTests {
    @Test func closingPanDoesNotRequireTheInputsThatOriginallyAllowedOpening() throws {
        let state = WorkspaceNavigationState()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let host = NSObject()
        let pane = NSObject()
        var allowsOpening = true
        let interaction = WorkspaceSidebarInteraction(frame: window.bounds)
        window.addSubview(interaction)
        defer { interaction.detach(); interaction.removeFromSuperview() }
        interaction.configure(state: state, travel: 60, isRightToLeft: false) {
            WorkspaceSidebarNativeContext(hostID: ObjectIdentifier(host), paneID: ObjectIdentifier(pane),
                window: window, allowsOpening: allowsOpening)
        }
        #expect(state.openSidebar(eligible: true))
        state.completeSettlement(try #require(state.settlementID))
        #expect(interaction.gestureRecognizerShouldBegin(ClosingPan()))
        // For example, an active Timeline selection makes opening ineligible;
        // restoring the same shifted Surface must still be possible.
        allowsOpening = false
        #expect(interaction.gestureRecognizerShouldBegin(ClosingPan()))
    }
}

@MainActor
private final class ClosingPan: UIPanGestureRecognizer {
    override func velocity(in view: UIView?) -> CGPoint { CGPoint(x: -200, y: 0) }
}

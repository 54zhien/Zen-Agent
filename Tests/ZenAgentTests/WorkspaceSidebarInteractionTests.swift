import UIKit
import Testing
@testable import ZenAgent

@Suite("Sidebar native close admission")
@MainActor
struct WorkspaceSidebarInteractionTests {
    @Test func windowGeometryChangeCancelsRailButAnchorKeyboardChangeDoesNot() throws {
        let state = WorkspaceNavigationState()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let root = UIViewController()
        window.rootViewController = root
        root.loadViewIfNeeded()
        root.view.frame = window.bounds
        window.isHidden = false
        let interaction = WorkspaceSidebarInteraction(frame: window.bounds)
        root.view.addSubview(interaction)
        defer { interaction.detach(); interaction.removeFromSuperview(); window.isHidden = true }
        let host = NSObject(), pane = NSObject()
        func configure() {
            interaction.configure(state: state, travel: 60, isRightToLeft: false) {
                WorkspaceSidebarNativeContext(hostID: ObjectIdentifier(host), paneID: ObjectIdentifier(pane),
                    window: window, allowsOpening: true)
            }
        }
        configure()
        func ownedRecognizers() -> [UIGestureRecognizer] {
            ((window.gestureRecognizers ?? []) + (root.view.gestureRecognizers ?? []))
                .filter { $0.delegate === interaction }
        }
        let owned = ownedRecognizers()
        #expect(owned.count == 3)
        #expect(owned.first { $0 is UIScreenEdgePanGestureRecognizer }?.view === root.view)
        #expect(owned.filter { !($0 is UIScreenEdgePanGestureRecognizer) }.allSatisfy { $0.view === window })
        #expect(state.openSidebar(eligible: true))
        state.completeSettlement(try #require(state.settlementID))
        interaction.frame.size.height = 450
        interaction.setNeedsLayout(); interaction.layoutIfNeeded()
        configure()
        #expect(state.isOpen)
        window.bounds = CGRect(x: 0, y: 0, width: 800, height: 400)
        root.view.frame = window.bounds
        interaction.frame = window.bounds
        interaction.setNeedsLayout(); interaction.layoutIfNeeded()
        configure()
        #expect(!state.isOpen && state.progress == 0 && state.settlementID == nil)
        let reattached = ownedRecognizers()
        #expect(Set(reattached.map(ObjectIdentifier.init)) == Set(owned.map(ObjectIdentifier.init)))
    }

    @Test func priorityBelongsOnlyToAnEligibleEdgeOrTheOpenSurfaceTap() throws {
        let state = WorkspaceNavigationState()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let surface = UIView(frame: window.bounds)
        let content = UIView(frame: surface.bounds)
        let rail = UIView(frame: CGRect(x: 0, y: 0, width: 60, height: 800))
        window.addSubview(surface); surface.addSubview(content); window.addSubview(rail)
        let interaction = WorkspaceSidebarInteraction(frame: window.bounds)
        window.addSubview(interaction)
        defer { interaction.detach(); interaction.removeFromSuperview() }
        let host = NSObject(), pane = NSObject()
        var eligible = true
        interaction.configure(state: state, travel: 60, isRightToLeft: false) {
            WorkspaceSidebarNativeContext(hostID: ObjectIdentifier(host), paneID: ObjectIdentifier(pane),
                window: window, allowsOpening: eligible, surfaceView: surface)
        }
        let edge = try #require(window.gestureRecognizers?.first {
            $0 is UIScreenEdgePanGestureRecognizer && $0.delegate === interaction
        })
        let tap = try #require(window.gestureRecognizers?.first {
            $0 is UITapGestureRecognizer && $0.delegate === interaction
        })
        let contentTap = UITapGestureRecognizer(); content.addGestureRecognizer(contentTap)
        let railTap = UITapGestureRecognizer(); rail.addGestureRecognizer(railTap)
        let systemEdge = UIScreenEdgePanGestureRecognizer(); content.addGestureRecognizer(systemEdge)
        func priority(_ owned: UIGestureRecognizer, _ other: UIGestureRecognizer) -> Bool {
            owned.delegate?.gestureRecognizer?(owned, shouldBeRequiredToFailBy: other) ?? false
        }
        // A live Full host alone is insufficient: priority requires an actual
        // leading touch admitted by the Window transport, exercised in UI tests.
        #expect(!priority(edge, contentTap))
        #expect(!priority(tap, contentTap))
        #expect(!priority(edge, systemEdge))
        eligible = false
        #expect(!priority(edge, contentTap))
        #expect(state.openSidebar(eligible: true))
        state.completeSettlement(try #require(state.settlementID))
        #expect(priority(tap, contentTap))
        #expect(!priority(tap, railTap))
        #expect(!priority(edge, contentTap))
        #expect(!priority(tap, edge))
        state.closeSidebar()
        #expect(!priority(tap, contentTap))
    }

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

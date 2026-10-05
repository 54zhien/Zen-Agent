import UIKit
import Testing
@testable import ZenAgent

@Suite("Sidebar native close admission")
@MainActor
struct WorkspaceSidebarInteractionTests {
    @Test(arguments: [false, true])
    func nativeEdgeCanAskBeforeItsFirstMotionSample(rightToLeft: Bool) {
        let fixture = SidebarEdgeFixture(rightToLeft: rightToLeft)
        defer { fixture.interaction.detach() }
        #expect(fixture.receive())
        #expect(fixture.interaction.gestureRecognizerShouldBegin(fixture.edge))
        fixture.send(.began)
        #expect(!fixture.state.isDragging && fixture.state.progress == 0)
        fixture.edge.point.x += rightToLeft ? -20 : 20
        fixture.send(.changed)
        #expect(fixture.state.isDragging && abs(fixture.state.progress - 1.0 / 3.0) < 0.001)
        fixture.edge.point.x += rightToLeft ? -80 : 80
        fixture.send(.ended)
        #expect(fixture.state.isOpen && fixture.state.progress == 1)
    }

    @Test(arguments: ["stationary", "vertical", "reverse", "owner", "eligibility", "cancelled"])
    func provisionalEdgeNeverOpensWithoutEligibleHorizontalMotion(reason: String) {
        let fixture = SidebarEdgeFixture(rightToLeft: false)
        defer { fixture.interaction.detach() }
        #expect(fixture.receive())
        #expect(fixture.interaction.gestureRecognizerShouldBegin(fixture.edge))
        fixture.send(.began)
        #expect(!fixture.state.isDragging && fixture.state.progress == 0)
        switch reason {
        case "vertical": fixture.edge.point.y += 60
        case "reverse": fixture.edge.point.x -= 60
        case "owner": fixture.pane = NSObject(); fixture.edge.point.x += 60
        case "eligibility": fixture.allowsOpening = false; fixture.edge.point.x += 60
        default: break
        }
        fixture.send(reason == "cancelled" ? .cancelled : .changed)
        #expect(!fixture.state.isDragging && fixture.state.progress == 0)
        // Rejected motion cannot turn into an opening later in the same touch.
        if reason != "stationary" { fixture.edge.point = CGPoint(x: 101, y: 300) }
        fixture.send(.ended)
        #expect(!fixture.state.isOpen && !fixture.state.isDragging && fixture.state.progress == 0)
    }

    @Test(arguments: [false, true])
    func coalescedEdgeOpensFromInitialTouchWithoutVelocityOrTranslation(rightToLeft: Bool) throws {
        let fixture = SidebarEdgeFixture(rightToLeft: rightToLeft)
        defer { fixture.interaction.detach() }
        #expect(fixture.receive())
        fixture.edge.point.x += rightToLeft ? -20 : 20
        #expect(fixture.interaction.gestureRecognizerShouldBegin(fixture.edge))
        fixture.send(.began)
        #expect(abs(fixture.state.progress - 1.0 / 3.0) < 0.001)
        // The release may be the next callback, after the Surface has shifted.
        fixture.edge.point.x += rightToLeft ? -80 : 80
        fixture.send(.ended)
        #expect(fixture.state.isOpen && fixture.state.progress == 1)
        fixture.state.reset()
        // The previous touch cannot grant a later gesture ownership.
        #expect(!fixture.interaction.gestureRecognizerShouldBegin(fixture.edge))
    }

    @Test func zeroVelocityFallbackStillRejectsVerticalReverseInteriorAndUnownedTouches() {
        let fixture = SidebarEdgeFixture(rightToLeft: false)
        defer { fixture.interaction.detach() }
        for offset in [CGPoint(x: 0, y: 50), CGPoint(x: 10, y: 50), CGPoint(x: -30, y: 0)] {
            #expect(fixture.receive())
            fixture.edge.point = CGPoint(x: 1 + offset.x, y: 300 + offset.y)
            #expect(!fixture.interaction.gestureRecognizerShouldBegin(fixture.edge))
        }
        #expect(fixture.receive(origin: CGPoint(x: 100, y: 300)))
        fixture.edge.point.x += 100
        #expect(!fixture.interaction.gestureRecognizerShouldBegin(fixture.edge))
        #expect(fixture.receive())
        fixture.edge.point.x += 100
        fixture.pane = NSObject()
        #expect(!fixture.interaction.gestureRecognizerShouldBegin(fixture.edge))
    }

    @Test(arguments: [false, true])
    func coalescedEdgeCancellationOrOwnerChangeRestoresClosedState(changeOwner: Bool) {
        let fixture = SidebarEdgeFixture(rightToLeft: false)
        defer { fixture.interaction.detach() }
        #expect(fixture.receive())
        fixture.edge.point.x += 40
        #expect(fixture.interaction.gestureRecognizerShouldBegin(fixture.edge))
        fixture.send(.began)
        #expect(fixture.state.isDragging && fixture.state.progress > 0)
        if changeOwner { fixture.pane = NSObject() }
        fixture.send(changeOwner ? .ended : .cancelled)
        #expect(!fixture.state.isOpen && !fixture.state.isDragging && fixture.state.progress == 0)
    }

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

@MainActor
private final class SidebarInitialTouch: UITouch {
    let point: CGPoint
    init(point: CGPoint) { self.point = point; super.init() }
    override func location(in view: UIView?) -> CGPoint { point }
}

@MainActor
private final class SidebarSampleEdge: UIScreenEdgePanGestureRecognizer {
    var sampleState: UIGestureRecognizer.State = .possible
    var point = CGPoint.zero
    override var state: UIGestureRecognizer.State {
        get { sampleState }
        set { sampleState = newValue }
    }
    override func location(in view: UIView?) -> CGPoint { point }
    override func translation(in view: UIView?) -> CGPoint { .zero }
    override func velocity(in view: UIView?) -> CGPoint { .zero }
}

@MainActor
private final class SidebarEdgeFixture {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
    let state = WorkspaceNavigationState()
    let edge = SidebarSampleEdge()
    let interaction: WorkspaceSidebarInteraction
    let host = NSObject()
    var pane = NSObject()
    var allowsOpening = true
    let rightToLeft: Bool

    init(rightToLeft: Bool) {
        self.rightToLeft = rightToLeft
        interaction = WorkspaceSidebarInteraction(frame: window.bounds, edge: edge)
        window.addSubview(interaction)
        interaction.configure(state: state, travel: 60, isRightToLeft: rightToLeft) { [unowned self] in
            WorkspaceSidebarNativeContext(hostID: ObjectIdentifier(host), paneID: ObjectIdentifier(pane),
                window: window, allowsOpening: allowsOpening)
        }
    }

    func receive(origin: CGPoint? = nil) -> Bool {
        edge.point = origin ?? CGPoint(x: rightToLeft ? 399 : 1, y: 300)
        edge.sampleState = .possible
        return interaction.gestureRecognizer(edge, shouldReceive: SidebarInitialTouch(point: edge.point))
    }

    func send(_ state: UIGestureRecognizer.State) {
        edge.sampleState = state
        _ = interaction.perform(NSSelectorFromString("changed:"), with: edge)
    }
}

import SwiftUI
import Testing
import UIKit
@testable import ZenAgent

@Suite("Sidebar system gesture deferral", .serialized)
@MainActor
struct SidebarSystemGestureTests {
    @Test(arguments: [LayoutDirection.leftToRight, .rightToLeft])
    func nativeRootDefersOnlyAnAdmittedLeadingEdge(direction: LayoutDirection) async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let state = WorkspaceNavigationState()
        let surface = UIView()
        let owner = NSObject(), pane = NSObject()
        var eligible = true
        var available = true
        var nativePresent = true
        func root() -> some View {
            WorkspaceNavigationView(state: state, spatiallyAvailable: available, context: {
                guard nativePresent else { return nil }
                return WorkspaceSidebarNativeContext(hostID: ObjectIdentifier(owner), paneID: ObjectIdentifier(pane),
                    window: window, allowsOpening: eligible, surfaceView: surface)
            }) { Color.clear }
            .environment(\.layoutDirection, direction)
        }
        let host = UIHostingController(rootView: root())
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        let leading: UIRectEdge = direction == .rightToLeft ? .right : .left
        func expectNativeEdges(_ expected: UIRectEdge) async {
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            // Let a rebuilt SwiftUI preference reach UIKit before a negative
            // check can match the preceding root's empty preference.
            try? await Task.sleep(for: .milliseconds(5))
            for _ in 0..<100 {
                if host.preferredScreenEdgesDeferringSystemGestures == expected { break }
                try? await Task.sleep(for: .milliseconds(5))
            }
            #expect(host.preferredScreenEdgesDeferringSystemGestures == expected)
        }
        await expectNativeEdges(leading)

        // The admitted drag keeps its edge until UIKit finishes the attempt,
        // including the interval after native end and before visual settlement.
        try #require(state.begin(eligible: true))
        eligible = false; host.rootView = root()
        await expectNativeEdges(leading)
        state.drag(displacement: 60, travel: 60)
        state.end(velocity: 0, travel: 60, cancelled: false)
        await expectNativeEdges(leading)
        eligible = true; host.rootView = root()
        await expectNativeEdges(leading)
        state.completeSettlement(try #require(state.settlementID))
        await expectNativeEdges([])

        eligible = false; state.reset(); host.rootView = root()
        await expectNativeEdges([])
        eligible = true; available = false; host.rootView = root()
        await expectNativeEdges([])
        available = true; host.rootView = root()
        await expectNativeEdges(leading)
        nativePresent = false; host.rootView = root()
        await expectNativeEdges([])
        nativePresent = true; host.rootView = root()
        await expectNativeEdges(leading)
        try #require(state.presentNewSettings(eligible: true))
        await expectNativeEdges([])
    }
}

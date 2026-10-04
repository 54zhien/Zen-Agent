import SwiftUI
import UIKit
import Testing
@testable import ZenAgent

@Suite("Retained Sidebar native Surface")
@MainActor
struct SidebarSurfaceTests {
    @Test func nativeLayoutRetainsNavigationCenterWithoutChangingLiftTransformOrHostBounds() {
        let host = ConversationSurfaceViewController(content: Text("Retained content"))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        let bounds = host.surfaceView.bounds
        let transform = host.surfaceView.transform
        let child = host.contentController
        host.setSidebar(offset: 90, settlement: nil, completion: nil)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        #expect(host.surfaceView.center.x == host.view.bounds.midX + 90)
        #expect(host.surfaceView.bounds == bounds && host.surfaceView.transform == transform)
        #expect(host.contentController === child)
        host.cancelSidebar()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        #expect(host.surfaceView.center.x == host.view.bounds.midX)
        #expect(host.surfaceView.bounds == bounds && host.contentController === child)
    }

    @Test func liveNavigationBlocksLiftUntilItsMatchingNativeCompletion() throws {
        let state = WorkspaceNavigationState()
        let lift = SurfaceLiftController()
        lift.workspaceNavigation = state
        #expect(!lift.workspaceNavigationActive)
        #expect(state.openSidebar(eligible: true))
        #expect(lift.workspaceNavigationActive)
        state.closeSidebar()
        #expect(lift.workspaceNavigationActive)
        state.completeSettlement(try #require(state.settlementID))
        #expect(!lift.workspaceNavigationActive)
    }
}

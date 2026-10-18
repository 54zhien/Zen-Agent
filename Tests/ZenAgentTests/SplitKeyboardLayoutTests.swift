import SwiftUI
import UIKit
import Testing
@testable import ZenAgent

@Suite("Split keyboard viewport ownership", .serialized)
@MainActor
struct SplitKeyboardLayoutTests {
    @Test(arguments: [false, true])
    func keyboardRetargetingDoesNotTakeOverSidebarTransport(picker: Bool) throws {
        let host = ConversationSurfaceViewController(content: Text("retained native root"))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        let background = picker ? UIColor(white: 0.09, alpha: 1) : UIColor.systemBackground
        host.setWorkspaceViewport(CGSize(width: 402, height: 437), backgroundColor: background)
        let child = host.contentController
        let root = child.view
        let transport = try #require(host.surfaceView.superview)
        #expect(transport !== host.view, "Sidebar translation must not animate the keyboard's center property")
        var completed: [UUID] = []
        let openingID = UUID()
        host.setSidebar(offset: 90, progress: 1, settlement: openingID) { completed.append($0) }
        let opening = try #require(host.sidebarAnimatorForTesting)
        opening.pauseAnimation()
        opening.fractionComplete = 0.35
        for height in [CGFloat(260), 420, 290, 437, 240, 437] {
            host.setWorkspaceViewport(CGSize(width: 402, height: height), backgroundColor: background)
            #expect(host.sidebarAnimatorForTesting === opening)
            #expect(transport.transform == CGAffineTransform(translationX: 90, y: 0))
            #expect(host.surfaceView.center == CGPoint(x: 201, y: height / 2))
            #expect(host.surfaceView.bounds.height == height && child.view.bounds.height == height)
            #expect(host.surfaceView.transform == .identity)
            #expect(!child.safeAreaRegions.contains(.keyboard))
            #expect(host.surfaceView.backgroundColor == background)
            #expect(host.contentController === child && child.view === root)
        }
        let closingID = UUID()
        host.setSidebar(offset: 0, progress: 0, settlement: closingID) { completed.append($0) }
        let closing = try #require(host.sidebarAnimatorForTesting)
        #expect(closing !== opening)
        closing.pauseAnimation()
        closing.fractionComplete = 0.4
        host.setWorkspaceViewport(CGSize(width: 402, height: 300), backgroundColor: background)
        closing.stopAnimation(false)
        closing.finishAnimation(at: .end)
        #expect(completed == [closingID], "The interrupted opening must not settle the newer closing")
        #expect(transport.transform == .identity)
        #expect(host.surfaceView.center == CGPoint(x: 201, y: 150))
        #expect(host.contentController === child && child.view === root)
        host.cancelSidebar()
    }

    @Test(arguments: [false, true])
    func workspaceSizesRetainedSurfacesWithoutASecondKeyboardInset(picker: Bool) throws {
        let host = ConversationSurfaceViewController(content: Text("retained native root"))
        host.loadViewIfNeeded()
        let child = host.contentController
        let root = child.view
        let background = picker ? UIColor(white: 0.09, alpha: 1) : UIColor.systemBackground
        host.view.frame = CGRect(x: 0, y: 0, width: 402, height: 437)
        host.view.layoutIfNeeded()
        #expect(child.safeAreaRegions.contains(.keyboard))

        for height in [CGFloat(437), 400, 350, 280, 240, 280, 350, 437] {
            // The outer SwiftUI frame may arrive later than its animation update.
            // The native canvas must already use the same logical viewport.
            let size = CGSize(width: 402, height: height)
            host.setWorkspaceViewport(size, backgroundColor: background)
            #expect(!child.safeAreaRegions.contains(.keyboard))
            #expect(child.safeAreaRegions.contains(.container))
            #expect(host.surfaceView.bounds.size == size)
            #expect(host.surfaceView.center == CGPoint(x: 201, y: height / 2))
            #expect(child.view.bounds.size == size)
            #expect(host.surfaceView.backgroundColor == background)
            #expect(host.contentController === child && child.view === root)
            #expect(host.presentation.clipFraction == CGSize(width: 1, height: 1))
        }

        host.setWorkspaceViewport(nil)
        host.view.layoutIfNeeded()
        #expect(child.safeAreaRegions.contains(.keyboard))
        #expect(host.surfaceView.bounds.size == host.view.bounds.size)
        #expect(host.contentController === child && child.view === root)
    }

    @Test(arguments: [SplitWorkspaceAxis.topBottom, .leftRight])
    func everyKeyboardViewportIsFilledWithoutChangingTheSplitRatio(axis: SplitWorkspaceAxis) throws {
        let ratio = 0.63
        for height in [CGFloat(874), 800, 710, 620, 540, 490, 540, 710, 874] {
            let layout = try #require(SplitWorkspaceGeometry(
                viewport: CGRect(x: 0, y: 0, width: 402, height: height), ratio: ratio, axis: axis))
            if axis == .topBottom {
                #expect(layout.top.minY == 0 && layout.bottom.maxY == height)
                #expect(layout.top.maxY == layout.divider.minY)
                #expect(layout.divider.maxY == layout.bottom.minY)
                #expect(abs(layout.divider.midY / height - ratio) < 0.000001)
            } else {
                #expect(layout.top.minX == 0 && layout.bottom.maxX == 402)
                #expect(layout.top.maxX == layout.divider.minX)
                #expect(layout.divider.maxX == layout.bottom.minX)
                #expect(layout.top.height == height && layout.bottom.height == height)
            }
        }
    }
}

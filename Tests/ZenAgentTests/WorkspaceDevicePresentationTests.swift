import UIKit
import Testing
@testable import ZenAgent

@Suite("Workspace device presentation")
struct WorkspaceDevicePresentationTests {
    @Test func embeddedViewportChangeCancelsResizeWithoutChangingWindowBounds() {
        let window = NSObject()
        let before = WorkspaceLayoutContext(windowID: ObjectIdentifier(window),
            windowSize: CGSize(width: 1200, height: 800), frame: CGRect(x: 0, y: 0, width: 1200, height: 800), isPad: true)
        let after = WorkspaceLayoutContext(windowID: before.windowID,
            windowSize: before.windowSize, frame: CGRect(x: 0, y: 0, width: 800, height: 800), isPad: true)
        #expect(after.requiresResizeCancellation(from: before))
        #expect(!before.requiresResizeCancellation(from: before))
    }
    @Test func landscapePhoneUsesOnlyTheUserActiveLogicalPane() {
        var split = SplitWorkspaceState(sourceConversationID: "source", sourceSlot: .bottom)
        _ = split.occupy("other")
        split.setRatio(0.63)
        let landscape = CGSize(width: 800, height: 400)
        #expect(WorkspaceDevicePresentation.resolve(isPad: false, size: landscape, split: split) == .landscapeSingle(.top))
        split.select(.bottom)
        #expect(WorkspaceDevicePresentation.resolve(isPad: false, size: landscape, split: split) == .landscapeSingle(.bottom))
        #expect(WorkspaceDevicePresentation.resolve(isPad: false, size: CGSize(width: 400, height: 800), split: split) == .split(.topBottom))
        #expect(split.sourceConversationID == "source" && split.secondaryConversationID == "other")
        #expect(split.topBottomRatio == 0.63 && split.activeSlot == .bottom)
        #expect(WorkspaceDevicePresentation.resolve(isPad: false, size: landscape, split: nil) == .single)
    }

    @Test func padKeepsAnExplicitAxisAndItsSeparateRatios() throws {
        var split = SplitWorkspaceState(sourceConversationID: "source", sourceSlot: .top)
        _ = split.occupy("other")
        let identity = split.arrangementID
        split.setRatio(0.61)
        split.selectAxis(.leftRight)
        #expect(split.activeRatio == 0.5)
        split.setRatio(0.42)
        let landscape = CGSize(width: 1200, height: 800)
        #expect(WorkspaceDevicePresentation.resolve(isPad: true, size: landscape, split: split) == .split(.leftRight))
        split.selectAxis(.topBottom)
        #expect(split.activeRatio == 0.61)
        split.selectAxis(.leftRight)
        #expect(split.activeRatio == 0.42)
        #expect(WorkspaceDevicePresentation.resolve(isPad: true,
            size: CGSize(width: 800, height: 1200), split: split) == .split(.leftRight))
        let replaced = SplitWorkspaceState(sourceConversationID: "replacement", sourceSlot: .top, preserving: split)
        #expect(replaced.axis == .leftRight && replaced.activeRatio == 0.42)
        #expect(replaced.topBottomRatio == 0.61 && replaced.arrangementID == identity)
        #expect(split.activeSlot == .bottom && split.secondaryConversationID == "other")
        let layout = try #require(SplitWorkspaceGeometry(size: landscape,
            safeArea: UIEdgeInsets(top: 20, left: 30, bottom: 25, right: 40), ratio: split.activeRatio, axis: .leftRight))
        #expect(layout.top.maxX == layout.bottom.minX)
        #expect(layout.divider.minX == layout.top.maxX)
        #expect(layout.top.width + layout.divider.width + layout.bottom.width == layout.viewport.width)
        #expect(layout.divider.width == 28 && layout.divider.height == layout.viewport.height)
        #expect(layout.top.height == layout.bottom.height)
    }
}

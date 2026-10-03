import Testing
import UIKit
@testable import ZenAgent

@Suite("Split Workspace ownership")
struct SplitWorkspaceStateTests {
    @Test("ratio geometry stays finite, shares one safe viewport, and survives source replacement")
    func ratioGeometryAndReplacement() throws {
        var split = SplitWorkspaceState(sourceConversationID: "source", sourceSlot: .top)
        split.setRatio(0.62)
        split.setRatio(.nan)
        split.setRatio(.infinity)
        split.setRatio(0)
        #expect(split.topBottomRatio == 0.62)
        let replaced = SplitWorkspaceState(sourceConversationID: "replacement", sourceSlot: .top, preserving: split)
        #expect(replaced.arrangementID == split.arrangementID)
        #expect(replaced.topBottomRatio == split.topBottomRatio)
        let layout = try #require(SplitWorkspaceGeometry(size: CGSize(width: 400, height: 800),
            safeArea: UIEdgeInsets(top: 50, left: 10, bottom: 30, right: 15), ratio: split.topBottomRatio))
        #expect(layout.top.maxY == layout.bottom.minY)
        #expect(layout.divider.midY == layout.top.maxY)
        #expect(layout.top.height + layout.bottom.height == layout.viewport.height)
        #expect(SplitWorkspaceGeometry(size: .zero, safeArea: .zero, ratio: 0.5) == nil)
        #expect(SplitWorkspaceGeometry(size: CGSize(width: 400, height: 800), safeArea: .zero, ratio: .nan) == nil)
        #expect(SplitWorkspaceGeometry.projectedRatio(0.1, minimum: 0.25) > 0.1)
        #expect(SplitWorkspaceGeometry.snappedRatio(0.495, minimum: 0.25) == 0.5)
    }
    @Test("one Conversation cannot own both Panes")
    func duplicateConversationIsRejected() {
        var split = SplitWorkspaceState(sourceConversationID: "source", sourceSlot: .bottom)
        #expect(split.emptySlot == .top)
        #expect(split.activeSlot == .bottom)
        let acceptedDuplicate = split.occupy("source")
        #expect(!acceptedDuplicate)
        #expect(split.secondaryConversationID == nil)
        split.select(.top)
        #expect(split.activeSlot == .bottom)
        let acceptedOther = split.occupy("other")
        #expect(acceptedOther)
        #expect(split.secondaryConversationID == "other")
        #expect(split.activeSlot == .top)
    }
}

import Foundation

enum SplitWorkspaceAxis: Equatable, Sendable { case topBottom, leftRight }

struct SplitWorkspaceState: Equatable {
    let arrangementID: UUID
    let sourceConversationID: String
    let sourceSlot: SplitDropSlot
    private(set) var secondaryConversationID: String?
    private(set) var activeSlot: SplitDropSlot
    private(set) var topBottomRatio: Double
    private(set) var leftRightRatio: Double
    private(set) var axis: SplitWorkspaceAxis
    var activeRatio: Double { axis == .topBottom ? topBottomRatio : leftRightRatio }

    init(sourceConversationID: String, sourceSlot: SplitDropSlot,
         preserving previous: SplitWorkspaceState? = nil) {
        arrangementID = previous?.arrangementID ?? UUID()
        topBottomRatio = previous?.topBottomRatio ?? 0.5
        leftRightRatio = previous?.leftRightRatio ?? 0.5
        axis = previous?.axis ?? .topBottom
        self.sourceConversationID = sourceConversationID
        self.sourceSlot = sourceSlot
        activeSlot = sourceSlot
    }

    mutating func setRatio(_ ratio: Double) {
        guard ratio.isFinite, ratio > 0, ratio < 1 else { return }
        if axis == .topBottom { topBottomRatio = ratio } else { leftRightRatio = ratio }
    }

    mutating func selectAxis(_ axis: SplitWorkspaceAxis) { self.axis = axis }

    mutating func restoreLayout(from previous: Self) {
        axis = previous.axis
        topBottomRatio = previous.topBottomRatio
        leftRightRatio = previous.leftRightRatio
    }

    var emptySlot: SplitDropSlot { sourceSlot == .top ? .bottom : .top }

    mutating func occupy(_ id: String) -> Bool {
        guard !id.isEmpty, id != sourceConversationID else { return false }
        secondaryConversationID = id
        activeSlot = emptySlot
        return true
    }

    mutating func select(_ slot: SplitDropSlot) {
        guard slot == sourceSlot || secondaryConversationID != nil else { return }
        activeSlot = slot
    }
}

import Foundation

struct SplitWorkspaceState: Equatable {
    let arrangementID: UUID
    let sourceConversationID: String
    let sourceSlot: SplitDropSlot
    private(set) var secondaryConversationID: String?
    private(set) var activeSlot: SplitDropSlot
    private(set) var topBottomRatio: Double

    init(sourceConversationID: String, sourceSlot: SplitDropSlot,
         preserving previous: SplitWorkspaceState? = nil) {
        arrangementID = previous?.arrangementID ?? UUID()
        topBottomRatio = previous?.topBottomRatio ?? 0.5
        self.sourceConversationID = sourceConversationID
        self.sourceSlot = sourceSlot
        activeSlot = sourceSlot
    }

    mutating func setRatio(_ ratio: Double) {
        guard ratio.isFinite, ratio > 0, ratio < 1 else { return }
        topBottomRatio = ratio
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

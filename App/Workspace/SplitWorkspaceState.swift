struct SplitWorkspaceState: Equatable {
    let sourceConversationID: String
    let sourceSlot: SplitDropSlot
    private(set) var secondaryConversationID: String?
    private(set) var activeSlot: SplitDropSlot

    init(sourceConversationID: String, sourceSlot: SplitDropSlot) {
        self.sourceConversationID = sourceConversationID
        self.sourceSlot = sourceSlot
        activeSlot = sourceSlot
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

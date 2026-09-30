import Testing
@testable import ZenAgent

@Suite("Split Workspace ownership")
struct SplitWorkspaceStateTests {
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

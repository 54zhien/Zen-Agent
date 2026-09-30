import Testing
@testable import ZenAgent

@Suite("Split Workspace ownership")
struct SplitWorkspaceStateTests {
    @Test("one Conversation cannot own both Panes")
    func duplicateConversationIsRejected() {
        var split = SplitWorkspaceState(sourceConversationID: "source", sourceSlot: .bottom)
        #expect(split.emptySlot == .top)
        #expect(split.activeSlot == .bottom)
        #expect(!split.occupy("source"))
        #expect(split.secondaryConversationID == nil)
        split.select(.top)
        #expect(split.activeSlot == .bottom)
        #expect(split.occupy("other"))
        #expect(split.secondaryConversationID == "other")
        #expect(split.activeSlot == .top)
    }
}

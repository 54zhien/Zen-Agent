import Foundation

extension AppShellModel {
    /// Search and Sidebar share the same active-Pane navigation policy as input.
    @MainActor
    func openActivePaneConversation(id: String) async -> Bool {
        if let split = splitWorkspace, split.activeSlot == split.emptySlot,
           id != split.sourceConversationID {
            return await openInSplit(id: id)
        }
        return await openConversation(id: id, presentation: .resting)
    }
}

import Observation

@MainActor
@Observable
final class ConversationPreviewController {
    private(set) var summaries: [ConversationSummary] = []
    private(set) var isPresented = false
    private(set) var errorMessage: String?
}

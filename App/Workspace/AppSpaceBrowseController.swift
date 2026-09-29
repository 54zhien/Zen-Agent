import Foundation
import Observation

@MainActor
@Observable
final class AppSpaceBrowseController {
    typealias Reader = (String) throws -> ConversationBrowseWindow
    private(set) var state = AppSpaceBrowseState(selected: .newConversation, older: nil, newer: nil)
    private(set) var summaries: [ConversationSummary] = []
    private(set) var errorMessage: String?
    var currentSummary: ConversationSummary? { nil }
    @ObservationIgnored private var reader: Reader?

    init(reader: Reader? = nil) { self.reader = reader }
    func present(originID: String) {}
    func refresh() {}
    func begin() -> Bool { false }
    func drag(displacement: Double, travel: Double) -> Bool { false }
    func end(velocity: Double, travel: Double, cancelled: Bool = false) -> AppSpaceBrowseState.Settlement? { nil }
    func complete(_ settlement: AppSpaceBrowseState.Settlement, finished: Bool) -> Bool { false }
    func cancel() {}
}

import Foundation
import Observation

@MainActor
@Observable
final class AppSpaceConversationDeletion {
    typealias RunAction = @MainActor (String) async throws -> Void

    private(set) var pending: PendingCardDeletion?
    private(set) var errorMessage: String?

    @ObservationIgnored private let store: PersistenceStore
    @ObservationIgnored private let stopRun: RunAction
    @ObservationIgnored private let waitForRun: RunAction
    @ObservationIgnored private let now: @MainActor () -> Date

    init(store: PersistenceStore, stopRun: @escaping RunAction,
         waitForRun: @escaping RunAction, now: @escaping @MainActor () -> Date) {
        self.store = store
        self.stopRun = stopRun
        self.waitForRun = waitForRun
        self.now = now
    }

    // Runnable seam for the coordinated Stop tests. The behavior follows their
    // compiled CI RED; no Card Delete is performed by this placeholder.
    func delete(conversationID: String, stillSelected: @escaping @MainActor () -> Bool) async -> Bool {
        false
    }
}

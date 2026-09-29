import Foundation
import Observation

@MainActor
@Observable
final class AppSpaceConversationActions {
    private(set) var errorMessage: String?
    init(store: PersistenceStore) { }
    func create(originID: String, at now: Date) throws -> String {
        throw PersistenceError.invalidTransition("App Space creation is not implemented")
    }
    func acknowledgeCreated(id: String) { }
    func reset() { }
}

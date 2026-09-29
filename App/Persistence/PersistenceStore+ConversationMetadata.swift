import Foundation

extension PersistenceStore {
    func createEmptyConversation(id: String, at now: Date) throws {
        throw PersistenceError.invalidTransition("Explicit empty creation is not implemented")
    }
    func renameConversation(id: String, title: String, at now: Date) throws { }
    func setConversationPinned(id: String, pinned: Bool, at now: Date) throws { }
    func hasManualConversationTitle(id: String) throws -> Bool { false }
}

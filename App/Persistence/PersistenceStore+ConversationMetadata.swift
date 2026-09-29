import Foundation

struct ConversationInitialBinding: Equatable, Sendable {
    let providerInstanceID: ProviderInstanceID?
    let modelID: ModelID?
    init(providerInstanceID: ProviderInstanceID? = nil, modelID: ModelID? = nil) {
        self.providerInstanceID = providerInstanceID
        self.modelID = modelID
    }
}

extension PersistenceStore {
    func createEmptyConversation(id: String, at now: Date, initialBinding: ConversationInitialBinding = .init()) throws {
        throw PersistenceError.invalidTransition("Explicit empty creation is not implemented")
    }
    func conversationInitialBinding(id: String) throws -> ConversationInitialBinding? { nil }
    func initializeEmptyConversationBinding(id: String, binding: ConversationInitialBinding, at now: Date) throws -> Bool { false }
    func renameConversation(id: String, title: String, at now: Date) throws { }
    func setConversationPinned(id: String, pinned: Bool, at now: Date) throws { }
    func hasManualConversationTitle(id: String) throws -> Bool { false }
}

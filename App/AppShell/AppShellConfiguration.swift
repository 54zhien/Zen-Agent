import Foundation

enum ConversationConfigurationOwner: Equatable {
    case uncommitted(id: String)
    case persistedEmpty(id: String)
}

enum AppShellConfiguration {
    @MainActor
    static func owner(id: String, currentID: String, pane: ConversationPaneController?,
                      hasSplit: Bool, isPreviewPresented: Bool, store: PersistenceStore,
                      allowConfiguredUncommitted: Bool = false) throws -> ConversationConfigurationOwner? {
        guard id == currentID, let pane, pane.conversationID == id,
              !hasSplit, !isPreviewPresented else { return nil }
        // This observation also invalidates Sidebar capability after the first Send.
        _ = pane.hasPublishedTurn
        if try store.conversationLifecycle(id: id) == nil {
            guard allowConfiguredUncommitted || pane.composer.configuration == nil else { return nil }
            return .uncommitted(id: id)
        }
        guard pane.composer.configuration == nil,
              try store.canInitializeEmptyConversationBinding(id: id) else { return nil }
        return .persistedEmpty(id: id)
    }

    static func availability(for configuration: ConversationComposerConfiguration?,
                             store: PersistenceStore, provider: any ModelProvider,
                             credentials: any CredentialStoring) -> ComposerSendAvailability {
        guard let configuration else { return .unconfigured }
        do {
            _ = try AppAssembly.validateTarget(providerInstanceID: configuration.providerInstanceID,
                modelID: configuration.modelID, store: store, provider: provider, credentials: credentials)
            return .ready
        } catch let failure as AppTargetFailure {
            return .unavailable(failure.message)
        } catch {
            return .unavailable(AppTargetFailure.configurationUnavailable.message)
        }
    }

    static func availabilities(for configurations: [ConversationComposerConfiguration],
                               store: PersistenceStore, provider: any ModelProvider,
                               credentials: any CredentialStoring) async -> [ComposerSendAvailability] {
        await Task.detached(priority: .userInitiated) {
            configurations.map { availability(for: $0, store: store, provider: provider, credentials: credentials) }
        }.value
    }
}

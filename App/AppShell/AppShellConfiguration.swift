import Foundation

enum AppShellConfiguration {
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

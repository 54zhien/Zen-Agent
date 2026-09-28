#if DEBUG
import SwiftUI

@MainActor
struct ConversationPreviewUITestFixture: View {
    @State private var model: AppShellModel

    init() {
        do {
            let store = try ConversationPreviewUITestSeed.makeStore()
            let credentials = CredentialStore(secrets: KeychainSecretBackend(), metadataRepository: store)
            let provider = FakeProvider()
            let router = RunEventRouter()
            let runtime = AppAssembly.makeRuntime(store: store, provider: provider,
                credentials: credentials, router: router, toolRegistry: .empty)
            let defaults = UserDefaults(suiteName: "ZenAgent.PreviewHandoffUITest")!
            defaults.removePersistentDomain(forName: "ZenAgent.PreviewHandoffUITest")
            let model = AppShellModel(dependencies: AppAssembly.Dependencies(store: store,
                credentials: credentials, provider: provider, runtime: runtime, router: router), userDefaults: defaults)
            guard model.openConversation(id: "preview-ui-11") else { fatalError("Preview history fixture could not open") }
            _model = State(initialValue: model)
        } catch {
            fatalError("Preview fixture could not assemble: \(error)")
        }
    }

    var body: some View { AppShellRootView(model: model) }
}
#endif

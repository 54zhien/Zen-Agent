#if DEBUG
import SwiftUI

@MainActor
struct ConversationPreviewUITestFixture: View {
    @State private var model: AppShellModel
    @State private var positionRequest: UInt64?
    @State private var didOpenHistory = false

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
            _model = State(initialValue: model)
        } catch {
            fatalError("Preview fixture could not assemble: \(error)")
        }
    }

    var body: some View {
        AppShellRootView(model: model)
            .task {
                guard !didOpenHistory else { return }
                didOpenHistory = true
                guard await model.openConversation(id: "preview-ui-11") else {
                    if !Task.isCancelled { fatalError("Preview history fixture could not open") }
                    return
                }
            }
            .overlay(alignment: .bottomLeading) {
                Text("pending=\(String(describing: model.pane?.scrollRequest?.sequence)) \(model.pane?.previewReadingDiagnosticForUITest ?? "Preview")")
                    .font(.system(size: 1)).frame(width: 1, height: 1)
                    .accessibilityIdentifier("preview-reading-diagnostic")
            }
            .overlay(alignment: .topLeading) {
                if !model.previewContent.isPresented {
                    Button("Position older Turn") {
                        let deep = ProcessInfo.processInfo.environment["ZEN_PREVIEW_DEEP_READING_UI_TEST"] == "1"
                        let runID = "preview-reading-run-\(deep ? 120 : 10)"
                        if deep, positionRequest == nil {
                            // Fixture bootstrap only: place an actual long timeline at
                            // its middle once. Return must use the production restoration.
                            model.pane?.readingPosition.setReadingAnchorForUITest(
                                TurnAnchor(runID: runID, relativeViewportOffset: 0.2))
                            model.pane?.previewReadingBootstrapForUITest = runID
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(150))
                                model.pane?.restoreAnchorForUITest(TurnAnchor(runID: runID, relativeViewportOffset: 0.2))
                                positionRequest = model.pane?.scrollRequest?.sequence
                            }
                        } else {
                            model.pane?.restoreAnchorForUITest(TurnAnchor(runID: runID, relativeViewportOffset: 0.2))
                            positionRequest = model.pane?.scrollRequest?.sequence
                        }
                    }
                    .accessibilityIdentifier("preview-reading-position")
                    .accessibilityValue(positionRequest == nil ? "not-requested"
                        : (model.pane?.scrollRequest == nil ? "settled" : "restoring"))
                    .padding(.top, 100)
                }
            }
    }
}
#endif

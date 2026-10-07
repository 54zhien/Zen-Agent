#if DEBUG
import SwiftUI

@MainActor
struct ConversationPreviewUITestFixture: View {
    @State private var model: AppShellModel
    @State private var positionRequest: UInt64?
    @State private var didOpenHistory = false
    @State private var hiddenViewportInset: CGFloat = 0
    private let files: ManagedFileStore
    private let store: PersistenceStore

    init() {
        do {
            let reauthentication = ProcessInfo.processInfo.environment["ZEN_REAUTH_UI_TEST"] == "1"
            let store = ProcessInfo.processInfo.environment["ZEN_NEW_CONFIGURE_UI_TEST"] == "1" || reauthentication
                ? PersistenceStore(database: try ZenDatabase.inMemory())
                : try ConversationPreviewUITestSeed.makeStore()
            self.store = store
            let files = ManagedFileStore(applicationSupportRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent("PreviewFiles-\(UUID())", isDirectory: true),
                protectionRequirement: .bestEffort)
            self.files = files
            let credentials = CredentialStore(secrets: KeychainSecretBackend(), metadataRepository: store)
            let provider = FakeProvider()
            let router = RunEventRouter()
            let runtime = AppAssembly.makeRuntime(store: store, provider: provider,
                credentials: credentials, router: router, toolRegistry: .empty, managedFiles: files)
            let defaults = UserDefaults(suiteName: "ZenAgent.PreviewHandoffUITest")!
            defaults.removePersistentDomain(forName: "ZenAgent.PreviewHandoffUITest")
            if ProcessInfo.processInfo.environment["ZEN_EXISTING_CONFIGURE_UI_TEST"] == "1" {
                let reference = CredentialReference(id: "existing-configure-\(UUID())", kind: .apiKey)
                try credentials.provision(SecretValue("existing-configure-ui-fixture-key"), as: reference)
                try store.createProviderInstance(ProviderInstance(id: .init(rawValue: "existing-configure-account"),
                    providerID: .deepSeek, displayName: "Existing Configure fixture", baseURL: nil,
                    configRevision: .initial, credentialReference: reference))
            }
            if reauthentication {
                let id = ProviderInstanceID(rawValue: "reauth-ui-account")
                try store.createProviderInstance(ProviderInstance(id: id, providerID: .deepSeek,
                    displayName: "Reauth fixture", baseURL: nil, configRevision: .initial, credentialReference: nil))
                defaults.set(id.rawValue, forKey: AppShellModel.defaultInstanceIDKey)
                defaults.set("fake-model", forKey: AppShellModel.defaultModelIDKey)
            }
            let model = AppShellModel(dependencies: AppAssembly.Dependencies(store: store,
                credentials: credentials, provider: provider, runtime: runtime, router: router,
                managedFiles: files), userDefaults: defaults)
            _model = State(initialValue: model)
        } catch {
            fatalError("Preview fixture could not assemble: \(error)")
        }
    }

    var body: some View {
        AppShellRootView(model: model)
            .padding(.bottom, hiddenViewportInset)
            .task {
                guard !didOpenHistory else { return }
                didOpenHistory = true
                if ProcessInfo.processInfo.environment["ZEN_NEW_CONFIGURE_UI_TEST"] == "1"
                    || ProcessInfo.processInfo.environment["ZEN_REAUTH_UI_TEST"] == "1" { return }
                if ProcessInfo.processInfo.environment["ZEN_FILES_PREVIEW_UI_TEST"] == "1" {
                    let files = files, store = store
                    do {
                        try await Task.detached {
                            let copy = try files.ingest(data: Data("Managed native preview/export fixture".utf8),
                                displayName: "managed-preview.txt", mediaType: "text/plain", in: store)
                            let now = Date()
                            try store.createFileAsset(FileAssetRecord(id: "managed-preview-fixture",
                                displayName: copy.displayName, currentVersionID: "managed-preview-version",
                                origin: .imported, createdAt: now, updatedAt: now), initialVersion: FileAssetVersionRecord(
                                    id: "managed-preview-version", assetID: "managed-preview-fixture",
                                    contentFingerprint: copy.fingerprint, byteCount: copy.byteCount,
                                    mediaType: copy.mediaType, createdAt: now))
                            _ = try files.removeUnreferencedAsset(id: copy.assetID, in: store, protectedAssetIDs: [])
                        }.value
                    } catch {
                        if !Task.isCancelled { fatalError("Managed preview fixture could not seed") }
                        return
                    }
                }
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
                if model.previewContent.isPresented, model.splitWorkspace != nil,
                   model.previewSurfaceSlot != model.sourceSurfaceSlot {
                    Button("Queue hidden reading position") {
                        // Force a different mounted viewport without depending on
                        // the later device-rotation presentation policy.
                        hiddenViewportInset = 100
                        model.pane?.restoreAnchorForUITest(TurnAnchor(
                            runID: "preview-reading-run-12", relativeViewportOffset: 0.2))
                        positionRequest = model.pane?.scrollRequest?.sequence
                    }
                    .accessibilityIdentifier("preview-hidden-reading-position")
                    .accessibilityValue(model.pane?.scrollRequest == nil ? "settled" : "pending")
                    .padding(.top, 100)
                } else if !model.previewContent.isPresented {
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

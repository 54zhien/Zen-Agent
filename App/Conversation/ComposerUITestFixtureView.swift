#if DEBUG
import SwiftUI

private actor ComposerUITestRuns {
    private var sequence = 0
    private var latest: RunProjection?

    func start(_ command: SendCommand) -> String {
        sequence += 1
        let runID = "composer-ui-test-\(sequence)"
        latest = RunProjection(runID: runID, state: .completed)
        return runID
    }

    func projection() -> RunProjection? { latest }
}

@MainActor
private final class ComposerUITestFixture {
    let pane: ConversationPaneController
    let runtime: ConversationRuntime
    let bridge: ComposerRuntimeActionBridge

    init() throws {
        let conversationID = "composer-ui-test-conversation"
        let instanceID = ProviderInstanceID(rawValue: "composer-ui-test-instance")
        let modelID = ModelID(rawValue: "composer-ui-test-model")
        let database = try ZenDatabase.inMemory()
        let store = PersistenceStore(database: database)
        let credentials = CredentialStore(
            secrets: KeychainSecretBackend(), metadataRepository: store
        )
        runtime = ConversationRuntime(
            store: store, provider: FakeProvider(instanceID: instanceID),
            credentials: credentials, toolRegistry: .empty
        )
        pane = try ConversationPaneController(
            conversationID: conversationID,
            initialTimeline: ConversationTimelineProjection(conversationID: conversationID, turns: []),
            configuration: ConversationComposerConfiguration(
                providerInstanceID: instanceID, modelID: modelID
            ),
            coalescer: StreamingCoalescer(interval: .milliseconds(0)),
            tolerance: 12,
            loadTimeline: { _ in
                ConversationTimelineProjection(conversationID: conversationID, turns: [])
            }
        )
        let runs = ComposerUITestRuns()
        bridge = ComposerRuntimeActionBridge(
            start: { command in await runs.start(command) },
            stop: { _ in },
            models: { requested in
                [ModelDescriptor(
                    id: modelID, providerInstanceID: requested,
                    displayName: "UI Test Model", capabilities: [.text, .streaming]
                )]
            },
            projection: { _ in await runs.projection() },
            projectionUpdates: { _ in AsyncStream { $0.yield(nil) } }
        )
    }
}

@MainActor
struct ComposerUITestFixtureView: View {
    @State private var fixture: ComposerUITestFixture

    init() {
        do {
            _fixture = State(initialValue: try ComposerUITestFixture())
        } catch {
            fatalError("Composer UI fixture could not open in-memory storage: \(error)")
        }
    }

    var body: some View {
        NavigationStack {
            ConversationPaneView(
                pane: fixture.pane,
                runtime: fixture.runtime,
                actionBridge: fixture.bridge,
                maxProviderSteps: 4
            )
            .navigationTitle("新会话")
        }
    }
}
#endif

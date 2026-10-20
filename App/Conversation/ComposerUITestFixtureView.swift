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
        let timeline = ConversationTimelineProjection(
            conversationID: conversationID,
            turns: [ConversationTurn(
                runID: "composer-ui-test-existing-turn",
                items: [.userText("这是一条用于验证消息点击不会收起输入框的较长测试消息，点按后应当展开完整内容，并继续保持键盘和输入框的焦点。")]
            )]
        )
        let credentials = CredentialStore(
            secrets: KeychainSecretBackend(), metadataRepository: store
        )
        runtime = ConversationRuntime(
            store: store, provider: FakeProvider(instanceID: instanceID),
            credentials: credentials, toolRegistry: .empty
        )
        pane = try ConversationPaneController(
            conversationID: conversationID,
            initialTimeline: timeline,
            configuration: ConversationComposerConfiguration(
                providerInstanceID: instanceID, modelID: modelID
            ),
            coalescer: StreamingCoalescer(interval: .milliseconds(0)),
            tolerance: 12,
            loadTimeline: { _ in timeline }
        )
        let runs = ComposerUITestRuns()
        bridge = ComposerRuntimeActionBridge(
            start: { command in await runs.start(command) },
            stop: { _ in },
            models: { requested in
                [ModelDescriptor(
                    id: modelID, providerInstanceID: requested,
                    displayName: "UI Test Model", capabilities: [.text, .streaming, .reasoning],
                    thinkingEfforts: ProcessInfo.processInfo.environment["ZEN_COMPOSER_THINKING_LEVELS_TEST"] == "1"
                        ? [.low, .high, .max] : Set(ThinkingEffort.allCases), defaultThinkingEffort: .high
                ), ModelDescriptor(
                    id: ModelID(rawValue: "composer-ui-test-long-model"), providerInstanceID: requested,
                    displayName: "UI Test Model With A Longer Name", capabilities: [.text, .streaming, .reasoning],
                    thinkingEfforts: [.low, .medium, .high, .xhigh], defaultThinkingEffort: .medium
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
        if ProcessInfo.processInfo.environment["ZEN_COMPOSER_SYMBOL_PREVIEW"] == "1" {
            VStack(spacing: 12) {
                Text("思考图标 · 六档").font(.title2)
                ForEach(ThinkingEffort.allCases, id: \.rawValue) { level in
                    HStack(spacing: 20) {
                        ComposerThinkingIcon(level: level)
                            .frame(width: 21, height: 21)
                            .frame(width: 38, height: 38)
                            .background(Color(uiColor: .secondarySystemFill), in: Circle())
                        Text(level.title).font(.body)
                        Spacer()
                        ComposerThinkingIcon(level: level)
                            .frame(width: 56, height: 56)
                            .frame(width: 70, height: 70)
                            .background(Color(uiColor: .secondarySystemFill), in: Circle())
                    }
                    .frame(height: 76)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemBackground))
        } else {
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
}
#endif

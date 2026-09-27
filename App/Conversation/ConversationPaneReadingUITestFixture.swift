#if DEBUG
import SwiftUI

private actor ConversationReadingUITestRuns {
    private var latest: RunProjection?

    func start(_: SendCommand) -> String {
        let runID = "conversation-reading-ui-test-send"
        latest = RunProjection(runID: runID, state: .completed)
        return runID
    }

    func projection() -> RunProjection? { latest }
}

@MainActor
private final class ConversationPaneReadingUITestFixture {
    let pane: ConversationPaneController
    let runtime: ConversationRuntime
    let bridge: ComposerRuntimeActionBridge

    private let conversationID = "conversation-reading-ui-test-conversation"
    private let finalRunID = "conversation-reading-ui-test-run-19"
    private let finalMessageID = "conversation-reading-ui-test-message-19"
    private let livePartID = "conversation-reading-ui-test-live-part"

    init() throws {
        let instanceID = ProviderInstanceID(rawValue: "conversation-reading-ui-test-instance")
        let modelID = ModelID(rawValue: "conversation-reading-ui-test-model")
        let timeline = Self.makeTimeline(conversationID: conversationID)
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let credentials = CredentialStore(
            secrets: KeychainSecretBackend(),
            metadataRepository: store
        )
        let runtime = ConversationRuntime(
            store: store,
            provider: FakeProvider(instanceID: instanceID),
            credentials: credentials,
            toolRegistry: .empty
        )
        let pane = try ConversationPaneController(
            conversationID: conversationID,
            initialTimeline: ConversationTimelineProjection(conversationID: conversationID, turns: []),
            configuration: ConversationComposerConfiguration(
                providerInstanceID: instanceID,
                modelID: modelID
            ),
            coalescer: StreamingCoalescer(interval: .milliseconds(0)),
            loadTimeline: { _ in timeline }
        )
        _ = try pane.reloadTimeline()

        let runs = ConversationReadingUITestRuns()
        let bridge = ComposerRuntimeActionBridge(
            start: { command in await runs.start(command) },
            stop: { _ in },
            models: { requestedInstanceID in
                [ModelDescriptor(
                    id: modelID,
                    providerInstanceID: requestedInstanceID,
                    displayName: "Reading Gate Test Model",
                    capabilities: [.text, .streaming]
                )]
            },
            projection: { _ in await runs.projection() },
            projectionUpdates: { _ in AsyncStream { $0.yield(nil) } }
        )
        self.pane = pane
        self.runtime = runtime
        self.bridge = bridge
    }

    func injectAssistantDelta() {
        do {
            _ = try pane.consume(
                .messagePartStarted(
                    runID: finalRunID,
                    messageID: finalMessageID,
                    partID: livePartID,
                    kind: .text
                ),
                in: conversationID
            )
            let delta = "CONTROLLED_LIVE_ASSISTANT_DELTA"
            _ = try pane.consume(
                .messagePartDelta(
                    runID: finalRunID,
                    partID: livePartID,
                    delta: delta,
                    endUTF8Offset: delta.utf8.count
                ),
                in: conversationID
            )
        } catch {
            assertionFailure("The controlled live delta could not reach the Conversation Pane: \(error)")
        }
    }

    private static func makeTimeline(conversationID: String) -> ConversationTimelineProjection {
        let turns = (0..<20).map { index in
            let assistantText = index == 10
                ? "OLDER_READING_POSITION_ANCHOR_TURN_10"
                : "Assistant response for Turn \(index)"
            return ConversationTurn(
                runID: "conversation-reading-ui-test-run-\(index)",
                items: [
                    .userText("User prompt for Turn \(index)"),
                    .assistantText(assistantText),
                ]
            )
        }
        return ConversationTimelineProjection(conversationID: conversationID, turns: turns)
    }
}

@MainActor
struct ConversationPaneReadingUITestFixtureView: View {
    @State private var fixture: ConversationPaneReadingUITestFixture

    init() {
        do {
            _fixture = State(initialValue: try ConversationPaneReadingUITestFixture())
        } catch {
            fatalError("Conversation reading UI fixture could not be created: \(error)")
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
            .navigationTitle("Conversation")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Inject live delta") {
                        fixture.injectAssistantDelta()
                    }
                    .accessibilityIdentifier("conversation-reading-test-inject-delta")
                    .accessibilityValue(String(describing: fixture.pane.readingPosition.mode))
                }
            }
        }
    }
}
#endif

import Foundation
import Observation

struct AppExecutionTarget: Equatable, Sendable {
    let providerInstanceID: ProviderInstanceID
    let modelID: ModelID
}

struct RecentConversationSummary: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
}

enum AppShellLaunchState: Equatable {
    case notStarted
    case loading
    case ready
    case failed(AppAssemblyFailure)
}

@MainActor
@Observable
final class AppShellModel {
    static let defaultInstanceIDKey = "zen.w1.defaultTarget.v1.instanceID"
    static let defaultModelIDKey = "zen.w1.defaultTarget.v1.modelID"
    static let maxProviderSteps = 4

    private(set) var launchState: AppShellLaunchState = .notStarted
    private(set) var conversationID = UUID().uuidString
    private(set) var target: AppExecutionTarget?
    private(set) var targetMessage: String?
    private(set) var recentConversations: [RecentConversationSummary] = []
    private(set) var pane: ConversationPaneController?
    private(set) var actionBridge: ComposerRuntimeActionBridge?
    private(set) var providerSetup: ProviderSetupModel?
    private(set) var router: RunEventRouter

    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private var dependencies: AppAssembly.Dependencies?
    @ObservationIgnored private var startedAssembly = false

    var canSend: Bool {
        target != nil && pane != nil && actionBridge != nil
    }

    var runtimeForPresentation: ConversationRuntime? {
        dependencies?.runtime
    }

    var persistedTurnCount: Int {
        pane?.liveStore.state.timeline.turns.count ?? 0
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.router = RunEventRouter()
    }

    init(
        dependencies: AppAssembly.Dependencies,
        userDefaults: UserDefaults
    ) {
        self.userDefaults = userDefaults
        self.dependencies = dependencies
        self.router = dependencies.router
        self.launchState = .ready
        self.startedAssembly = true
        prepareProviderSetup()
        loadDefaultTarget()
        refreshRecentConversations()
    }

    func assembleIfNeeded() {
        guard !startedAssembly else { return }
        assemble()
    }

    func assemble() {
        startedAssembly = true
        launchState = .loading
        dependencies = nil
        pane = nil
        actionBridge = nil
        target = nil
        targetMessage = nil
        recentConversations = []
        providerSetup = nil
        router = RunEventRouter()

        do {
            let assembled = try AppAssembly.assemble(router: router)
            dependencies = assembled
            launchState = .ready
            prepareProviderSetup()
            loadDefaultTarget()
            refreshRecentConversations()
        } catch let failure as AppAssemblyFailure {
            launchState = .failed(failure)
        } catch {
            launchState = .failed(.wiring(summary: String(reflecting: type(of: error))))
        }
    }

    func newConversation() {
        router.unregisterPane(for: conversationID)
        // Lifecycle draft retention can snapshot the outgoing Composer before this pane is replaced.
        pane = nil
        actionBridge = nil
        conversationID = UUID().uuidString
        installPaneIfReady()
        refreshRecentConversations()
    }

    func refreshRecentConversations() {
        guard let store = dependencies?.store else {
            recentConversations = []
            return
        }

        do {
            let visible = try store.visibleConversations().sorted { left, right in
                if left.userActiveAt != right.userActiveAt {
                    return left.userActiveAt > right.userActiveAt
                }
                return left.id < right.id
            }
            recentConversations = visible.map { conversation in
                RecentConversationSummary(
                    id: conversation.id,
                    title: recentTitle(for: conversation, in: store)
                )
            }
        } catch {
            recentConversations = []
        }
    }

    @discardableResult
    func openConversation(id: String) -> Bool {
        guard let dependencies, let target else { return false }
        guard let visibleIDs = try? dependencies.store.visibleConversations().map(\.id),
              visibleIDs.contains(id) else { return false }

        if id == conversationID, pane != nil {
            return true
        }

        do {
            let timeline = try ConversationTimelineLoader.load(
                conversationID: id,
                from: dependencies.store
            )
            let wiring = try makePane(
                id: id,
                initialTimeline: timeline,
                dependencies: dependencies,
                target: target
            )
            guard dependencies.router.registerPane(wiring.pane) else { return false }

            // Keep the outgoing pane intact until the replacement has loaded and registered.
            // A warm-timeout draft cache can capture its Composer immediately before replacement.
            let outgoingConversationID = conversationID
            router.unregisterPane(for: outgoingConversationID)
            conversationID = id
            actionBridge = wiring.bridge
            pane = wiring.pane
            return true
        } catch {
            return false
        }
    }

    private func prepareProviderSetup() {
        guard let dependencies else { return }
        providerSetup = ProviderSetupModel(
            store: dependencies.store,
            credentials: dependencies.credentials,
            provider: dependencies.provider,
            userDefaults: userDefaults,
            onTargetSaved: { [weak self] savedTarget in
                self?.targetWasSaved(savedTarget)
            }
        )
    }

    private func loadDefaultTarget() {
        guard let dependencies else { return }
        guard let instanceRawValue = userDefaults.string(forKey: Self.defaultInstanceIDKey),
              let modelRawValue = userDefaults.string(forKey: Self.defaultModelIDKey),
              !instanceRawValue.isEmpty,
              !modelRawValue.isEmpty else {
            target = nil
            targetMessage = "尚未配置模型"
            return
        }

        let candidate = AppExecutionTarget(
            providerInstanceID: ProviderInstanceID(rawValue: instanceRawValue),
            modelID: ModelID(rawValue: modelRawValue)
        )
        do {
            _ = try AppAssembly.validateTarget(
                providerInstanceID: candidate.providerInstanceID,
                modelID: candidate.modelID,
                store: dependencies.store,
                provider: dependencies.provider,
                credentials: dependencies.credentials
            )
            target = candidate
            targetMessage = nil
            installPaneIfReady()
        } catch let failure as AppTargetFailure {
            target = nil
            targetMessage = failure.message
        } catch {
            target = nil
            targetMessage = AppTargetFailure.configurationUnavailable.message
        }
    }

    private func targetWasSaved(_ savedTarget: AppExecutionTarget) {
        target = savedTarget
        targetMessage = nil
        guard let pane else {
            installPaneIfReady()
            return
        }
        pane.composer.configuration = ConversationComposerConfiguration(
            providerInstanceID: savedTarget.providerInstanceID,
            modelID: savedTarget.modelID
        )
    }

    private func targetBecameUnavailable(_ failure: AppTargetFailure) {
        target = nil
        targetMessage = failure.message
    }

    private func installPaneIfReady() {
        guard let dependencies, let target else { return }
        do {
            try installPane(
                initialTimeline: ConversationTimelineProjection(
                    conversationID: conversationID,
                    turns: []
                ),
                dependencies: dependencies,
                target: target
            )
        } catch {
            launchState = .failed(.wiring(summary: String(reflecting: type(of: error))))
        }
    }

    private func installPane(
        initialTimeline: ConversationTimelineProjection,
        dependencies: AppAssembly.Dependencies,
        target: AppExecutionTarget
    ) throws {
        let wiring = try makePane(
            id: conversationID,
            initialTimeline: initialTimeline,
            dependencies: dependencies,
            target: target
        )
        guard dependencies.router.registerPane(wiring.pane) else {
            throw AppTargetFailure.configurationUnavailable
        }
        actionBridge = wiring.bridge
        pane = wiring.pane
    }

    private func makePane(
        id: String,
        initialTimeline: ConversationTimelineProjection,
        dependencies: AppAssembly.Dependencies,
        target: AppExecutionTarget
    ) throws -> (bridge: ComposerRuntimeActionBridge, pane: ConversationPaneController) {
        let bridge = AppAssembly.wireConversation(
            id: id,
            dependencies: dependencies,
            onTargetFailure: { [weak self] failure in
                self?.targetBecameUnavailable(failure)
            }
        )
        let pane = try ConversationPaneController(
            conversationID: id,
            initialTimeline: initialTimeline,
            configuration: ConversationComposerConfiguration(
                providerInstanceID: target.providerInstanceID,
                modelID: target.modelID
            ),
            coalescer: StreamingCoalescer(interval: .milliseconds(10)),
            loadTimeline: { id in
                try ConversationTimelineLoader.load(conversationID: id, from: dependencies.store)
            }
        )
        return (bridge, pane)
    }

    private func recentTitle(
        for conversation: ConversationRecord,
        in store: PersistenceStore
    ) -> String {
        let storedTitle = Self.normalizedTitle(conversation.title)
        if !storedTitle.isEmpty { return Self.displayTitle(storedTitle) }

        guard let messages = try? store.messages(inConversation: conversation.id) else {
            return "未命名会话"
        }
        for message in messages where message.role == .user {
            guard let parts = try? store.parts(ofMessage: message.id) else { continue }
            for part in parts where part.kind == .text {
                guard let text = try? store.text(ofPart: part.id),
                      !Self.normalizedTitle(text).isEmpty else { continue }
                return Self.displayTitle(Self.normalizedTitle(text))
            }
        }
        return "未命名会话"
    }

    private static func normalizedTitle(_ title: String) -> String {
        title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func displayTitle(_ title: String) -> String {
        let limit = 56
        guard title.count > limit else { return title }
        return String(title.prefix(limit - 1)) + "…"
    }
}

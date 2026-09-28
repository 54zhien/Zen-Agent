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
    private(set) var sendAvailability: ComposerSendAvailability = .unconfigured
    private(set) var recentConversations: [RecentConversationSummary] = []
    private(set) var recentLoadError: String?
    private var recentCursor: ConversationSummaryCursor?
    var recentHasMore: Bool { recentCursor != nil }

    // New UI capability scaffolds stay inert until their compiled behavior RED.
    func loadMoreRecentConversations() {}
    func retryRecentConversations() {}
    private(set) var pane: ConversationPaneController?
    private(set) var actionBridge: ComposerRuntimeActionBridge?
    private(set) var providerSetup: ProviderSetupModel?
    private(set) var coldStartRecoveryMessage: String?
    private(set) var router: RunEventRouter

    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private var dependencies: AppAssembly.Dependencies?
    @ObservationIgnored private var startedAssembly = false
    @ObservationIgnored private var backgroundedAtInProcess: Date?
    @ObservationIgnored private var sessionsByConversationID: [String: ConversationSession] = [:]

    var canSend: Bool {
        pane?.composer.sendAvailability.isReady == true
            && pane?.composer.configuration != nil && actionBridge != nil
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
        beginColdStartRecoveryThenRestore(at: Date())
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
        sendAvailability = .unconfigured
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
            beginColdStartRecoveryThenRestore(at: Date())
        } catch let failure as AppAssemblyFailure {
            launchState = .failed(failure)
        } catch {
            launchState = .failed(.wiring(summary: String(reflecting: type(of: error))))
        }
    }

    func newConversation() {
        rememberCurrentSession()
        router.unregisterPane(for: conversationID)
        pane = nil
        actionBridge = nil
        conversationID = UUID().uuidString
        installPaneIfReady()
        refreshRecentConversations()
    }

    func enteredBackground(at date: Date) {
        backgroundedAtInProcess = date
        guard isCurrentConversationVisible else {
            ConversationResumeMarker.clear(from: userDefaults)
            return
        }
        ConversationResumeMarker(
            conversationID: conversationID,
            backgroundedAt: date
        ).write(to: userDefaults)
    }

    func becameActive(at date: Date) {
        guard let backgroundedAtInProcess else { return }
        self.backgroundedAtInProcess = nil
        ConversationResumeMarker.clear(from: userDefaults)
        let marker = ConversationResumeMarker(
            conversationID: conversationID,
            backgroundedAt: backgroundedAtInProcess
        )
        if !marker.isWithinRestoreWindow(at: date), isCurrentConversationVisible {
            newConversation()
        }
    }

    private func restoreAtLaunch(at date: Date) {
        let marker = ConversationResumeMarker.read(from: userDefaults)
        guard let marker else { return }
        guard marker.isWithinRestoreWindow(at: date) else {
            ConversationResumeMarker.clear(from: userDefaults)
            return
        }
        if openConversation(id: marker.conversationID) {
            ConversationResumeMarker.clear(from: userDefaults)
            return
        }
        guard let store = dependencies?.store else { return }
        do {
            if try store.conversationLifecycle(id: marker.conversationID) != .visible {
                ConversationResumeMarker.clear(from: userDefaults)
            }
        } catch {
            // A transient read failure must leave the marker available for retry.
        }
    }

    private func beginColdStartRecoveryThenRestore(at date: Date) {
        guard let dependencies else { return }
        do {
            guard !((try dependencies.store.activeParentRunIDs()).isEmpty) else {
                restoreAtLaunch(at: date)
                return
            }
        } catch {
            coldStartRecoveryMessage = "无法检查未完成的运行，请重试恢复。"
            return
        }

        launchState = .loading
        Task { [weak self] in
            guard let self else { return }
            do {
                let report = try await dependencies.runtime.reconcileColdStartRuns()
                coldStartRecoveryMessage = report.needsRetry
                    ? "部分运行尚未恢复，可阅读历史并重试恢复。"
                    : nil
            } catch {
                coldStartRecoveryMessage = "无法恢复未完成的运行，请重试恢复。"
            }
            launchState = .ready
            restoreAtLaunch(at: date)
        }
    }

    func retryColdStartRecovery() {
        guard let runtime = dependencies?.runtime else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let report = try await runtime.retryColdStartRecovery()
                coldStartRecoveryMessage = report.needsRetry
                    ? "部分运行尚未恢复，可阅读历史并重试恢复。"
                    : nil
            } catch {
                coldStartRecoveryMessage = "无法恢复未完成的运行，请重试恢复。"
            }
        }
    }

    private var isCurrentConversationVisible: Bool {
        guard let store = dependencies?.store else { return false }
        return (try? store.conversationLifecycle(id: conversationID)) == .visible
    }

    private func rememberCurrentSession() {
        guard let pane, let store = dependencies?.store else { return }
        do {
            guard try store.conversationLifecycle(id: conversationID) == .visible else { return }
        } catch {
            // A failed read cannot prove this is a disposable uncommitted page.
            sessionsByConversationID[conversationID] = pane.session
            return
        }
        sessionsByConversationID[conversationID] = pane.session
    }

    func refreshRecentConversations() {
        guard let store = dependencies?.store else { return }
        do {
            let page = try store.conversationSummaryPage()
            recentConversations = page.items.map { RecentConversationSummary(id: $0.id, title: $0.title) }
            recentCursor = page.nextCursor
            recentLoadError = nil
        } catch {
            // Preserve the last readable page and its cursor so failure remains retryable.
            recentLoadError = "会话列表读取失败，请重试。"
        }
    }

    @discardableResult
    func openConversation(id: String) -> Bool {
        guard let dependencies else { return false }
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
            rememberCurrentSession()
            let outgoingConversationID = conversationID
            router.unregisterPane(for: outgoingConversationID)
            conversationID = id
            actionBridge = wiring.bridge
            pane = wiring.pane
            sendAvailability = wiring.pane.composer.sendAvailability
            targetMessage = sendAvailability.message
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
            sendAvailability = .unconfigured
            installPaneIfReady()
            return
        }

        let candidate = AppExecutionTarget(
            providerInstanceID: ProviderInstanceID(rawValue: instanceRawValue),
            modelID: ModelID(rawValue: modelRawValue)
        )
        target = candidate
        sendAvailability = .checking
        do {
            _ = try AppAssembly.validateTarget(
                providerInstanceID: candidate.providerInstanceID,
                modelID: candidate.modelID,
                store: dependencies.store,
                provider: dependencies.provider,
                credentials: dependencies.credentials
            )
            sendAvailability = .ready
            targetMessage = nil
        } catch let failure as AppTargetFailure {
            sendAvailability = .unavailable(failure.message)
            targetMessage = failure.message
        } catch {
            sendAvailability = .unavailable(AppTargetFailure.configurationUnavailable.message)
            targetMessage = AppTargetFailure.configurationUnavailable.message
        }
        installPaneIfReady()
    }

    private func targetWasSaved(_ savedTarget: AppExecutionTarget) {
        target = savedTarget
        targetMessage = nil
        sendAvailability = .ready
        guard let pane else {
            installPaneIfReady()
            return
        }
        guard let dependencies else { return }
        do {
            // The existing setup entry changes the global default. Only a page
            // with no committed Conversation may adopt that choice directly.
            if try dependencies.store.conversationLifecycle(id: conversationID) == nil {
                pane.composer.configuration = ConversationComposerConfiguration(
                    providerInstanceID: savedTarget.providerInstanceID, modelID: savedTarget.modelID)
            }
            pane.composer.sendAvailability = availability(for: pane.composer.configuration, in: dependencies)
        } catch {
            pane.composer.sendAvailability = .unavailable(AppTargetFailure.persistenceUnavailable.message)
        }
        sendAvailability = pane.composer.sendAvailability
        targetMessage = sendAvailability.message
    }

    private func targetBecameUnavailable(
        _ failure: AppTargetFailure,
        for failedTarget: AppExecutionTarget,
        conversationID ownerID: String
    ) {
        let owner = conversationID == ownerID ? pane?.composer : sessionsByConversationID[ownerID]?.composer
        guard let owner, owner.configuration == ConversationComposerConfiguration(
            providerInstanceID: failedTarget.providerInstanceID,
            modelID: failedTarget.modelID
        ) else { return }
        // A bridge outlives its display. Its asynchronous failure belongs to the
        // captured session, even when the new display selected identical IDs.
        owner.sendAvailability = .unavailable(failure.message)
        if conversationID == ownerID {
            targetMessage = failure.message
            sendAvailability = owner.sendAvailability
        }
    }

    private func installPaneIfReady() {
        guard let dependencies else { return }
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
        target: AppExecutionTarget?
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
        sendAvailability = wiring.pane.composer.sendAvailability
        targetMessage = sendAvailability.message
    }

    private func makePane(
        id: String,
        initialTimeline: ConversationTimelineProjection,
        dependencies: AppAssembly.Dependencies,
        target: AppExecutionTarget?
    ) throws -> (bridge: ComposerRuntimeActionBridge, pane: ConversationPaneController) {
        let savedSession = sessionsByConversationID[id]
        var configuration: ConversationComposerConfiguration?
        if let savedSession {
            configuration = savedSession.composer.configuration
        } else if try dependencies.store.conversationLifecycle(id: id) != nil {
            // Compatibility for history created before durable Conversation binding.
            // This is an initial choice, never a rewrite of an old frozen Run seed.
            if let seed = try dependencies.store.runs(inConversation: id)
                .last(where: { $0.kind == .parent })?.requestConfigSeed {
                configuration = ConversationComposerConfiguration(
                    providerInstanceID: seed.providerInstanceID, modelID: seed.modelID)
            }
        } else {
            configuration = target.map {
                ConversationComposerConfiguration(providerInstanceID: $0.providerInstanceID, modelID: $0.modelID)
            }
        }
        let validatedAvailability = availability(for: configuration, in: dependencies)
        let bridge = AppAssembly.wireConversation(
            id: id,
            dependencies: dependencies,
            onTargetFailure: { [weak self] failure, failedTarget in
                self?.targetBecameUnavailable(failure, for: failedTarget, conversationID: id)
            }
        )
        let pane = try ConversationPaneController(
            conversationID: id,
            initialTimeline: initialTimeline,
            configuration: configuration,
            sendAvailability: validatedAvailability,
            session: savedSession,
            coalescer: StreamingCoalescer(interval: .milliseconds(10)),
            loadTimeline: { id in
                try ConversationTimelineLoader.load(conversationID: id, from: dependencies.store)
            }
        )
        pane.composer.sendAvailability = validatedAvailability
        return (bridge, pane)
    }

    private func availability(for configuration: ConversationComposerConfiguration?,
                              in dependencies: AppAssembly.Dependencies) -> ComposerSendAvailability {
        guard let configuration else { return .unconfigured }
        do {
            _ = try AppAssembly.validateTarget(providerInstanceID: configuration.providerInstanceID,
                modelID: configuration.modelID, store: dependencies.store,
                provider: dependencies.provider, credentials: dependencies.credentials)
            return .ready
        } catch let failure as AppTargetFailure {
            return .unavailable(failure.message)
        } catch {
            return .unavailable(AppTargetFailure.configurationUnavailable.message)
        }
    }

}

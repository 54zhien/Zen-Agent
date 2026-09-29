import Foundation
import Observation

struct AppExecutionTarget: Equatable, Sendable {
    let providerInstanceID: ProviderInstanceID
    let modelID: ModelID
}

struct RecentConversationSummary: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    var previewStatus: ConversationPreviewStatus = .ready
    var contentUnavailable: Bool { previewStatus == .contentUnavailable }
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

    private var recentFailureWasNextPage = false

    func loadMoreRecentConversations() {
        guard let store = dependencies?.store, let cursor = recentCursor else { return }
        do {
            let page = try store.conversationSummaryPage(after: cursor)
            let existing = Set(recentConversations.map(\.id))
            recentConversations.append(contentsOf: page.items.filter { !existing.contains($0.id) }
                .map { RecentConversationSummary(id: $0.id, title: $0.title,
                    previewStatus: $0.contentUnavailable ? .contentUnavailable : .ready) })
            recentCursor = page.nextCursor
            recentLoadError = nil
            recentFailureWasNextPage = false
        } catch {
            recentFailureWasNextPage = true
            recentLoadError = "会话列表读取失败，请重试。"
        }
    }

    func retryRecentConversations() {
        guard recentLoadError != nil else { return }
        if recentFailureWasNextPage { loadMoreRecentConversations() }
        else { refreshRecentConversations() }
    }

    let previewContent = ConversationPreviewController()

    func enterPreview() -> Bool {
        guard let pane, let store = dependencies?.store else { return previewContent.isPresented }
        guard previewContent.present(session: pane.session, store: store) else { return false }
        rememberCurrentSession()
        // The current uncommitted page is also retained for Card/Return, without
        // adding durable Draft storage or changing navigation to another page.
        sessions.retain(pane.session, reconstruction: .unavailable)
        router.unregisterPane(for: conversationID)
        self.pane = nil
        actionBridge = nil
        return true
    }

    func preparePreviewReturn() async -> Bool {
        guard previewContent.isPresented, let dependencies,
              let session = previewContent.session else { return pane != nil }
        if previewContent.prepared != nil { return true }
        guard !previewContent.isPreparing else { return false }
        let id = conversationID
        let preparation = previewContent.beginPreparation()
        // A busy Run may invalidate a read. Retry a finite number of times; failure
        // leaves the Preview and its logical state intact for an explicit retry.
        for _ in 0..<3 {
            let ticket = router.beginPanePreparation(for: id)
            do {
                let history = try await router.historyPreparation.prepare(id: id, store: dependencies.store)
                guard !Task.isCancelled, conversationID == id,
                      router === dependencies.router, previewContent.accepts(preparation) else {
                    dependencies.router.cancelPanePreparation(for: id, ticket: ticket)
                    return false
                }
                guard router.acceptsPanePreparation(for: id, ticket: ticket) else { continue }
                let wiring = try ConversationPaneFactory(sessions: sessions).makePane(
                    id: id, initialTimeline: history.timeline, dependencies: dependencies, target: target,
                    snapshot: history.snapshot,
                    onTargetFailure: { [weak self] failure, failedTarget in
                        self?.targetBecameUnavailable(failure, for: failedTarget, conversationID: id)
                    })
                guard wiring.pane.session === session,
                      router.registerPreparedPane(wiring.pane, ticket: ticket) else { continue }
                // Receive durable Runtime events while still hidden behind Preview.
                previewContent.ready(wiring, id: preparation)
                return true
            } catch {
                dependencies.router.cancelPanePreparation(for: id, ticket: ticket)
                previewContent.failed(preparation)
                return false
            }
        }
        router.cancelPanePreparation(for: id)
        previewContent.failed(preparation)
        return false
    }

    func commitPreviewReturn() -> Bool {
        guard previewContent.isPresented, let prepared = previewContent.prepared,
              prepared.pane.conversationID == conversationID else { return false }
        pane = prepared.pane
        actionBridge = prepared.bridge
        commitSession(prepared.pane.session)
        sendAvailability = prepared.pane.composer.sendAvailability
        targetMessage = sendAvailability.message
        previewContent.finish()
        return true
    }

    func cancelPreviewReturn() {
        if previewContent.isPreparing { router.historyPreparation.cancel() }
        if let prepared = previewContent.prepared {
            router.unregisterPane(for: prepared.pane.conversationID)
        }
        router.cancelPanePreparation(for: conversationID)
        previewContent.cancelPreparation()
    }

    func refreshPreview() {
        if let store = dependencies?.store { previewContent.refresh(store: store) }
    }

    private(set) var pane: ConversationPaneController?
    private(set) var actionBridge: ComposerRuntimeActionBridge?
    private(set) var providerSetup: ProviderSetupModel?
    private(set) var coldStartRecoveryMessage: String?
    private(set) var router: RunEventRouter

    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private var dependencies: AppAssembly.Dependencies?
    @ObservationIgnored private var startedAssembly = false
    @ObservationIgnored private var backgroundedAtInProcess: Date?
    @ObservationIgnored private let sessions = ConversationSessionStore()
    @ObservationIgnored private var navigationID = UUID()
    @ObservationIgnored private(set) var launchRestorationTask: Task<Void, Never>?

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
        navigationID = UUID()
        router.historyPreparation.cancel()
        launchRestorationTask?.cancel()
        startedAssembly = true
        launchState = .loading
        cancelPreviewReturn()
        previewContent.finish()
        dependencies = nil
        sessions.removeAll()
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
        navigationID = UUID()
        router.historyPreparation.cancel()
        launchRestorationTask?.cancel()
        rememberCurrentSession()
        cancelPreviewReturn()
        previewContent.finish()
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

    private func restoreAtLaunch(at date: Date) async {
        let marker = ConversationResumeMarker.read(from: userDefaults)
        guard let marker else { return }
        guard marker.isWithinRestoreWindow(at: date) else {
            ConversationResumeMarker.clear(from: userDefaults)
            return
        }
        if await openConversation(id: marker.conversationID) {
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
                if ConversationResumeMarker.read(from: userDefaults) != nil {
                    launchRestorationTask = Task { [weak self] in
                        guard let self else { return }
                        await self.restoreAtLaunch(at: date)
                    }
                }
                return
            }
        } catch {
            coldStartRecoveryMessage = "无法检查未完成的运行，请重试恢复。"
            return
        }

        launchState = .loading
        launchRestorationTask = Task { [weak self] in
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
            guard !Task.isCancelled, router === dependencies.router else { return }
            await restoreAtLaunch(at: date)
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
        guard let session = pane?.session ?? previewContent.session,
              let store = dependencies?.store else { return }
        do {
            guard let summary = try store.conversationSummaryWindow(ids: [conversationID]).first else {
                sessions.remove(conversationID: conversationID)
                return
            }
            // Re-read the latest persisted Parent choice. An initial choice can
            // become stale after another Send, even if the user switches back to it.
            let configuration: ConversationComposerConfiguration?
            if let instanceID = summary.providerInstanceID, let modelID = summary.modelID {
                configuration = ConversationComposerConfiguration(providerInstanceID: instanceID, modelID: modelID)
            } else {
                configuration = nil
            }
            let unavailable = summary.contentUnavailable
                || (summary.runProjection != nil && configuration == nil)
            sessions.retain(session, reconstruction: unavailable
                ? .unavailable : .history(configuration: configuration))
        } catch {
            // A read failure cannot prove that the current owner is reconstructible.
            sessions.retain(session, reconstruction: .unavailable)
        }
    }

    private func commitSession(_ session: ConversationSession) {
        sessions.activate(session)
        sessions.evictIfNeeded(isRuntimeProtected: router.hasActiveRun(for:))
    }

    func refreshRecentConversations() {
        guard let store = dependencies?.store else { return }
        do {
            let page = try store.conversationSummaryPage()
            recentConversations = page.items.map { RecentConversationSummary(id: $0.id, title: $0.title,
                previewStatus: $0.contentUnavailable ? .contentUnavailable : .ready) }
            recentCursor = page.nextCursor
            recentLoadError = nil
            recentFailureWasNextPage = false
        } catch {
            // Preserve the last readable page and its cursor so failure remains retryable.
            recentFailureWasNextPage = false
            recentLoadError = "会话列表读取失败，请重试。"
        }
    }

    @discardableResult
    func openConversation(id: String) async -> Bool {
        guard let dependencies else { return false }
        guard (try? dependencies.store.conversationLifecycle(id: id)) == .visible else { return false }

        if id == conversationID {
            if pane != nil { return true }
            if previewContent.prepared != nil { return commitPreviewReturn() }
        }

        cancelPreviewReturn()
        let navigation = UUID()
        navigationID = navigation
        let ticket = router.beginPanePreparation(for: id)
        defer { dependencies.router.cancelPanePreparation(for: id, ticket: ticket) }
        do {
            let history = try await router.historyPreparation.prepare(id: id, store: dependencies.store)
            guard !Task.isCancelled, navigationID == navigation, router === dependencies.router,
                  history.snapshot.conversation?.lifecycle == .visible else { return false }
            let wiring = try ConversationPaneFactory(sessions: sessions).makePane(
                id: id,
                initialTimeline: history.timeline,
                dependencies: dependencies,
                target: target,
                snapshot: history.snapshot,
                onTargetFailure: { [weak self] failure, failedTarget in
                    self?.targetBecameUnavailable(failure, for: failedTarget, conversationID: id)
                }
            )
            guard dependencies.router.registerPreparedPane(wiring.pane, ticket: ticket) else { return false }

            // Keep the outgoing pane intact until the replacement has loaded and registered.
            rememberCurrentSession()
            cancelPreviewReturn()
            previewContent.finish()
            let outgoingConversationID = conversationID
            if outgoingConversationID != id { router.unregisterPane(for: outgoingConversationID) }
            conversationID = id
            actionBridge = wiring.bridge
            pane = wiring.pane
            commitSession(wiring.pane.session)
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
            pane.composer.sendAvailability = ConversationPaneFactory.availability(for: pane.composer.configuration, in: dependencies)
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
        let owner = conversationID == ownerID
            ? (pane?.composer ?? previewContent.session?.composer)
            : sessions.session(for: ownerID)?.composer
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
        let ownerID = conversationID
        let wiring = try ConversationPaneFactory(sessions: sessions).makePane(
            id: ownerID,
            initialTimeline: initialTimeline,
            dependencies: dependencies,
            target: target,
            onTargetFailure: { [weak self] failure, failedTarget in
                self?.targetBecameUnavailable(failure, for: failedTarget, conversationID: ownerID)
            }
        )
        guard dependencies.router.registerPane(wiring.pane) else {
            throw AppTargetFailure.configurationUnavailable
        }
        actionBridge = wiring.bridge
        pane = wiring.pane
        commitSession(wiring.pane.session)
        sendAvailability = wiring.pane.composer.sendAvailability
        targetMessage = sendAvailability.message
    }


}

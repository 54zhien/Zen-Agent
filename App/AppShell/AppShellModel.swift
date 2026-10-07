import Foundation
import Observation

struct AppExecutionTarget: Equatable, Sendable {
    let providerInstanceID: ProviderInstanceID
    let modelID: ModelID
}

enum ConversationOpenPresentation: Equatable { case preserved, resting }

struct RecentConversationSummary: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    var previewStatus: ConversationPreviewStatus = .ready
    var contentUnavailable: Bool { previewStatus == .contentUnavailable }
}

struct RecentConversationOpenFailure: Equatable, Sendable {
    let conversationID: String
    let message = "会话读取失败，原会话已保留。请重试打开。"
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
    var workspaceStore: PersistenceStore? { dependencies?.store }
    var workspaceFilesAvailable: Bool { dependencies?.managedFiles != nil }
    let appearance: AppearanceSettings
    let modelMenus: ModelMenuPreferences

    var currentSettingsNewID: String? {
        do { return try configurationOwner(id: conversationID, allowConfiguredUncommitted: true) == nil ? nil : conversationID }
        catch { return nil }
    }

    func configurationOwner(id: String) throws -> ConversationConfigurationOwner? {
        try configurationOwner(id: id, allowConfiguredUncommitted: false)
    }

    private func configurationOwner(id: String, allowConfiguredUncommitted: Bool) throws -> ConversationConfigurationOwner? {
        guard let dependencies else { return nil }
        return try AppShellConfiguration.owner(id: id, currentID: conversationID, pane: pane,
            hasSplit: splitWorkspace != nil, isPreviewPresented: previewContent.isPresented,
            store: dependencies.store, allowConfiguredUncommitted: allowConfiguredUncommitted)
    }

    func makeSettingsModel(configureNewID: String? = nil) -> SettingsWorkspaceModel? {
        guard let dependencies else { return nil }
        let capturedSession = pane?.session
        let onConfigure: (@MainActor (AppExecutionTarget) throws -> Bool)?
        if let configureNewID, capturedSession?.composer.configuration == nil {
            onConfigure = { [weak self, weak capturedSession] target in
                guard let self, let capturedSession, self.pane?.session === capturedSession else { return false }
                return try self.initializeConversationConfiguration(target, id: configureNewID)
            }
        } else { onConfigure = nil }
        return SettingsWorkspaceModel(store: dependencies.store, credentials: dependencies.credentials,
            provider: dependencies.provider, defaults: userDefaults, appearance: appearance, menus: modelMenus,
            files: dependencies.managedFiles,
            onConfigure: onConfigure,
            onProviderCommitted: { [weak self] instanceID in
                await self?.refreshSendAvailability(for: instanceID)
            }, onDefault: { [weak self] target, _ in
                self?.target = target
            })
    }

    private func initializeConversationConfiguration(_ target: AppExecutionTarget, id: String) throws -> Bool {
        guard let dependencies, let owner = try configurationOwner(id: id), let pane else { return false }
        switch owner {
        case .uncommitted: break
        case .persistedEmpty:
            // The read only exposes an affordance. This transaction remains the
            // authority if Send, deletion or another configuration has won first.
            guard try dependencies.store.initializeEmptyConversationBinding(id: id,
                binding: .init(providerInstanceID: target.providerInstanceID, modelID: target.modelID),
                at: Date()) else { return false }
        }
        pane.composer.configuration = .init(providerInstanceID: target.providerInstanceID, modelID: target.modelID)
        pane.composer.sendAvailability = AppShellConfiguration.availability(for: pane.composer.configuration,
            store: dependencies.store, provider: dependencies.provider, credentials: dependencies.credentials)
        sendAvailability = pane.composer.sendAvailability
        targetMessage = sendAvailability.message
        return true
    }

    func makeFilesWorkspaceModel() -> FilesWorkspaceModel? {
        guard let dependencies, let files = dependencies.managedFiles else { return nil }
        return FilesWorkspaceModel(store: dependencies.store, files: files, sessions: sessions)
    }

    func refreshSendAvailability(for instanceID: ProviderInstanceID) async {
        guard let dependencies else { return }
        let token = UUID()
        configurationRefreshIDs[instanceID] = token
        defer {
            if configurationRefreshIDs[instanceID] == token { configurationRefreshIDs[instanceID] = nil }
        }
        let targets: [(session: ConversationSession, configuration: ConversationComposerConfiguration)] =
            sessions.retainedSessions.compactMap { session in
                guard let configuration = session.composer.configuration,
                      configuration.providerInstanceID == instanceID else { return nil }
                return (session, configuration)
            }
        let results = await AppShellConfiguration.availabilities(for: targets.map(\.configuration),
            store: dependencies.store, provider: dependencies.provider, credentials: dependencies.credentials)
        guard configurationRefreshIDs[instanceID] == token, router === dependencies.router else { return }
        for (target, result) in zip(targets, results) {
            guard sessions.session(for: target.session.conversationID) === target.session,
                  target.session.composer.configuration == target.configuration else { continue }
            target.session.composer.sendAvailability = result
        }
        if let owner = pane?.composer ?? previewContent.session?.composer {
            sendAvailability = owner.sendAvailability
            targetMessage = owner.sendAvailability.message
        }
    }
    static let defaultInstanceIDKey = "zen.w1.defaultTarget.v1.instanceID"
    static let defaultModelIDKey = "zen.w1.defaultTarget.v1.modelID"
    static let maxProviderSteps = 4

    private(set) var launchState: AppShellLaunchState = .notStarted
    private(set) var conversationID = UUID().uuidString
    private(set) var splitWorkspace: SplitWorkspaceState?
    private(set) var workspaceLayoutRevision: UInt64 = 0

    func refreshWorkspaceLayout() { workspaceLayoutRevision += 1 }

    func setSplitRatio(_ ratio: Double) {
        guard ratio.isFinite, ratio > 0, ratio < 1,
              let split = splitWorkspace, split.activeRatio != ratio else { return }
        splitWorkspace?.setRatio(ratio)
        workspaceLayoutRevision += 1
    }

    func setSplitAxis(_ axis: SplitWorkspaceAxis) {
        guard splitWorkspace?.axis != axis, splitWorkspace != nil else { return }
        splitWorkspace?.selectAxis(axis)
        refreshWorkspaceLayout()
    }

    func restoreSplitConfiguration(_ captured: SplitWorkspaceState) {
        guard splitWorkspace?.arrangementID == captured.arrangementID,
              splitWorkspace?.sourceConversationID == captured.sourceConversationID,
              splitWorkspace?.secondaryConversationID == captured.secondaryConversationID else { return }
        splitWorkspace?.restoreLayout(from: captured)
        refreshWorkspaceLayout()
    }
    private(set) var splitPane: ConversationPaneController?
    private(set) var splitActionBridge: ComposerRuntimeActionBridge?
    private(set) var splitOpenError: String?
    private(set) var splitPreviewOriginSlot: SplitDropSlot?
    private var splitExistingOtherReturnID: String?
    private var borrowedPreviewOwner = false
    private var deletedSplitIDs: Set<String> = []
    private(set) var sourceSurfaceSlot: WorkspaceSurfaceSlot = .primary
    private(set) var previewSurfaceSlot: WorkspaceSurfaceSlot?
    var previewRestoresSplit: Bool { splitWorkspace != nil && deletedSplitIDs.isEmpty }
    private(set) var previewHandoffID: String?
    private(set) var target: AppExecutionTarget?
    private(set) var targetMessage: String?
    private(set) var sendAvailability: ComposerSendAvailability = .unconfigured
    private(set) var recentConversations: [RecentConversationSummary] = []
    private var recentListLoadError: String?
    private(set) var recentOpenFailure: RecentConversationOpenFailure?
    // List refresh cannot erase a failed Full Open's retry target.
    var recentLoadError: String? { recentOpenFailure?.message ?? recentListLoadError }
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
            recentListLoadError = nil
            recentFailureWasNextPage = false
        } catch {
            recentFailureWasNextPage = true
            recentListLoadError = "会话列表读取失败，请重试。"
        }
    }

    func retryRecentConversations() {
        guard recentListLoadError != nil else { return }
        if recentFailureWasNextPage { loadMoreRecentConversations() }
        else { refreshRecentConversations() }
    }

    let previewContent = ConversationPreviewController()

    func acceptsSplitDrop(_ intent: SplitDropIntent) -> Bool {
        launchState == .ready && splitWorkspace == nil && !previewContent.isPresented
            && pane?.conversationID == intent.conversationID
    }

    @discardableResult
    func commitSplitDrop(_ intent: SplitDropIntent) -> Bool {
        guard acceptsSplitDrop(intent) else { return false }
        splitWorkspace = SplitWorkspaceState(sourceConversationID: intent.conversationID,
                                             sourceSlot: intent.slot)
        return true
    }

    func selectSplitSlot(_ slot: SplitDropSlot) {
        guard let split = splitWorkspace, split.activeSlot != slot else { return }
        let outgoing = split.activeSlot == split.sourceSlot ? pane : splitPane
        let incoming = slot == split.sourceSlot ? pane : splitPane
        guard let incoming, outgoing?.composer.isComposing != true,
              outgoing?.composer.isSelectionHandleDragging != true,
              outgoing?.composer.quoteDragPhase == .idle else { return }
        let editing = outgoing?.composer.draft.presentationState == .editing
        if editing {
            _ = outgoing?.composer.handle(.keyboardDismissed)
            _ = incoming.composer.handle(.textAreaTapped)
        }
        splitWorkspace?.select(slot)
    }

    @discardableResult
    func createNewInSplit() -> Bool {
        guard var split = splitWorkspace, !previewContent.isPresented,
              split.sourceConversationID == conversationID, let dependencies else { return false }
        let id = UUID().uuidString
        do {
            let wiring = try ConversationPaneFactory(sessions: sessions).makePane(
                id: id, initialTimeline: ConversationTimelineProjection(conversationID: id, turns: []),
                dependencies: dependencies, target: target,
                onTargetFailure: { [weak self] failure, failedTarget in
                    self?.targetBecameUnavailable(failure, for: failedTarget, conversationID: id)
                })
            guard router.registerPane(wiring.pane) else { throw AppTargetFailure.configurationUnavailable }
            guard sessions.activate(wiring.pane.session, alongside: conversationID,
                                    isRuntimeProtected: router.hasActiveRun(for:)) else {
                router.unregisterPane(for: id)
                throw AppTargetFailure.configurationUnavailable
            }
            guard split.occupy(id) else { return false }
            retireSecondaryPane()
            cancelSplitSelection()
            splitPane = wiring.pane
            splitActionBridge = wiring.bridge
            splitWorkspace = split
            splitOpenError = nil
            return true
        } catch {
            splitOpenError = "无法创建会话，请重试。"
            return false
        }
    }

    @discardableResult
    func openInSplit(id: String) async -> Bool {
        guard let split = splitWorkspace, !previewContent.isPresented,
              id != split.sourceConversationID, let dependencies, !Task.isCancelled else { return false }
        if splitPane?.conversationID == id {
            selectSplitSlot(split.emptySlot)
            return true
        }
        let selection = UUID()
        splitSelectionID = selection
        if let splitOpenTicket {
            router.cancelPanePreparation(for: splitOpenTicket.conversationID, ticket: splitOpenTicket.ticket)
        }
        let ticket = router.beginPanePreparation(for: id)
        splitOpenTicket = (id, ticket)
        defer {
            router.cancelPanePreparation(for: id, ticket: ticket)
            if splitOpenTicket?.ticket == ticket { splitOpenTicket = nil }
        }
        do {
            let history = try await router.historyPreparation.prepare(id: id, store: dependencies.store)
            let warmOwner = sessions.uncommittedSession(for: id)
            guard !Task.isCancelled, splitSelectionID == selection,
                  splitWorkspace?.sourceConversationID == split.sourceConversationID,
                  splitWorkspace?.secondaryConversationID == split.secondaryConversationID,
                  router === dependencies.router else { return false }
            guard history.snapshot.conversation?.lifecycle == .visible
                    || (history.snapshot.conversation == nil && warmOwner != nil) else {
                splitOpenError = "无法打开会话，请重试。"
                return false
            }
            let wiring = try ConversationPaneFactory(sessions: sessions).makePane(
                id: id, initialTimeline: history.timeline, dependencies: dependencies,
                target: target, snapshot: history.snapshot,
                onTargetFailure: { [weak self] failure, failedTarget in
                    self?.targetBecameUnavailable(failure, for: failedTarget, conversationID: id)
                })
            guard (warmOwner == nil || wiring.pane.session === warmOwner),
                  router.registerPreparedPane(wiring.pane, ticket: ticket) else {
                splitOpenError = "无法打开会话，请重试。"
                return false
            }
            guard sessions.activate(wiring.pane.session, alongside: split.sourceConversationID,
                                    isRuntimeProtected: router.hasActiveRun(for:)) else {
                router.unregisterPane(for: id)
                splitOpenError = "无法打开会话，请重试。"
                return false
            }
            guard var committed = splitWorkspace,
                  committed.arrangementID == split.arrangementID else { return false }
            guard committed.occupy(id) else { return false }
            retireSecondaryPane()
            splitPane = wiring.pane
            splitActionBridge = wiring.bridge
            splitWorkspace = committed
            splitOpenError = nil
            return true
        } catch {
            if !Task.isCancelled, !(error is CancellationError), splitSelectionID == selection {
                splitOpenError = "无法打开会话，请重试。"
            }
            return false
        }
    }

    func closeSplit() {
        closeSplit(keeping: splitWorkspace?.sourceSlot ?? .top)
    }

    func closeSplit(keeping slot: SplitDropSlot) {
        if let split = splitWorkspace, slot != split.sourceSlot {
            guard let survivor = splitPane, let survivorBridge = splitActionBridge else { return }
            if let departing = pane {
                rememberSession(departing.session, id: departing.conversationID, retainUncommitted: true)
                router.unregisterPane(for: departing.conversationID)
                sessions.deactivate(departing.conversationID)
            }
            pane = survivor
            actionBridge = survivorBridge
            conversationID = survivor.conversationID
            sourceSurfaceSlot = sourceSurfaceSlot == .primary ? .secondary : .primary
            splitPane = nil
            splitActionBridge = nil
            sendAvailability = survivor.composer.sendAvailability
            targetMessage = sendAvailability.message
        } else {
            retireSecondaryPane()
        }
        cancelSplitSelection()
        splitWorkspace = nil
        splitPreviewOriginSlot = nil
        splitExistingOtherReturnID = nil
        previewSurfaceSlot = nil
        deletedSplitIDs = []
        splitOpenError = nil
        workspaceLayoutRevision += 1
        sessions.evictIfNeeded(isRuntimeProtected: router.hasActiveRun(for:))
    }

    private func cancelSplitSelection() {
        splitSelectionID = UUID()
        if let splitOpenTicket {
            router.cancelPanePreparation(for: splitOpenTicket.conversationID, ticket: splitOpenTicket.ticket)
            self.splitOpenTicket = nil
        }
    }

    private func retireSecondaryPane() {
        if let splitPane {
            rememberSession(splitPane.session, id: splitPane.conversationID, retainUncommitted: true)
            router.unregisterPane(for: splitPane.conversationID)
            sessions.deactivate(splitPane.conversationID)
        }
        splitPane = nil
        splitActionBridge = nil
    }

    func enterPreview() -> Bool {
        let originSlot = splitWorkspace?.activeSlot
        let fromSecondary = originSlot != nil && originSlot == splitWorkspace?.emptySlot
        guard let selected = fromSecondary ? splitPane : pane,
              let store = dependencies?.store else { return previewContent.isPresented }
        guard previewContent.present(session: selected.session, store: store) else { return false }
        splitSelectionID = UUID()
        if let splitOpenTicket {
            router.cancelPanePreparation(for: splitOpenTicket.conversationID,
                                         ticket: splitOpenTicket.ticket)
            self.splitOpenTicket = nil
        }
        splitPreviewOriginSlot = originSlot
        previewSurfaceSlot = fromSecondary ? sourceSurfaceSlot.other : sourceSurfaceSlot
        deletedSplitIDs = []
        splitExistingOtherReturnID = nil
        rememberSession(selected.session, id: selected.conversationID, retainUncommitted: true)
        router.unregisterPane(for: selected.conversationID)
        if fromSecondary {
            splitPane = nil
            splitActionBridge = nil
        } else {
            pane = nil
            actionBridge = nil
        }
        return true
    }

    private func previewOriginIsCurrent() -> Bool {
        guard let originID = previewContent.originID else { return false }
        guard let split = splitWorkspace else {
            return splitPreviewOriginSlot == nil && originID == conversationID
        }
        guard let slot = splitPreviewOriginSlot else { return false }
        return slot == split.sourceSlot
            ? originID == split.sourceConversationID
            : originID == split.secondaryConversationID
    }

    func newConversationBrowseWindow() throws -> ConversationBrowseWindow {
        guard previewContent.isPresented, let originID = previewContent.originID,
              let store = dependencies?.store else { throw AppTargetFailure.persistenceUnavailable }
        return try store.conversationNewBrowseWindow(originID: originID, uncommittedIDs: sessions.uncommittedIDs)
    }
    func createConversationFromAppSpace(at now: Date = Date()) throws -> String {
        guard previewContent.isPresented, !previewContent.isPreparing,
              let originID = previewContent.originID,
              let cardActions else { throw AppTargetFailure.persistenceUnavailable }
        let id = try cardActions.create(originID: originID, at: now, initialBinding:
            ConversationInitialBinding(providerInstanceID: target?.providerInstanceID, modelID: target?.modelID))
        refreshRecentConversations()
        return id
    }
    func appSpaceActionError(for id: String?) -> String? { cardActions?.error(for: id) }
    func acknowledgeAppSpaceCreation(id: String) { cardActions?.acknowledgeCreated(id: id) }
    func appSpaceConversationTitle(id: String) -> String? {
        guard previewContent.isPresented, !previewContent.isPreparing else { return nil }
        return cardActions?.title(id: id)
    }
    func renameAppSpaceConversation(id: String, title: String) -> Bool {
        guard previewContent.isPresented, !previewContent.isPreparing,
              cardActions?.rename(id: id, title: title) == true else { return false }
        refreshRecentConversations()
        return true
    }
    func pinAppSpaceConversation(id: String, pinned: Bool) -> Bool {
        guard previewContent.isPresented, !previewContent.isPreparing,
              cardActions?.pin(id: id, pinned: pinned) == true else { return false }
        refreshRecentConversations()
        return true
    }

    func deleteAppSpaceConversation(id: String, stillSelected: @MainActor () -> Bool) async -> Bool {
        guard previewContent.isPresented, !previewContent.isPreparing,
              let cardDeletion else { return false }
        let deleted = await cardDeletion.delete(conversationID: id, stillSelected: stillSelected)
        if deleted {
            detachDeletedSplitPane(id: id)
            refreshRecentConversations()
        }
        return deleted
    }

    private func detachDeletedSplitPane(id: String) {
        guard let split = splitWorkspace,
              id == split.sourceConversationID || id == split.secondaryConversationID else { return }
        deletedSplitIDs.insert(id)
        cancelSplitSelection()
        if previewContent.preparationTargetID == id { cancelPreviewReturn() }
        let affected = pane?.conversationID == id ? pane : splitPane?.conversationID == id ? splitPane : nil
        if let affected {
            // The durable row is hidden during Undo. A history-based retention
            // check would discard precisely the draft Undo still needs.
            sessions.retain(affected.session, reconstruction: .unavailable)
            router.unregisterPane(for: id)
            sessions.deactivate(id)
        }
        if pane?.conversationID == id { pane = nil; actionBridge = nil }
        if splitPane?.conversationID == id { splitPane = nil; splitActionBridge = nil }
    }

    func undoAppSpaceConversation(id: String) -> Bool {
        guard let cardDeletion, cardDeletion.undo(conversationID: id) else { return false }
        refreshRecentConversations()
        return true
    }

    func restoreRecoveredAppSpaceConversation(id: String) -> Bool {
        guard let cardDeletion, cardDeletion.restoreRecovered(conversationID: id) else { return false }
        refreshRecentConversations()
        return true
    }

    func confirmRecoveredAppSpaceConversationDeletion(id: String) -> Bool {
        guard let cardDeletion, cardDeletion.confirmRecovered(conversationID: id) else { return false }
        refreshRecentConversations()
        return true
    }

    func browseWindow(id: String) throws -> ConversationBrowseWindow {
        guard let store = dependencies?.store else { throw AppTargetFailure.persistenceUnavailable }
        return try store.conversationBrowseWindow(id: id, uncommittedIDs: sessions.uncommittedIDs)
    }

    func preparePreviewReturn(to requestedID: String? = nil) async -> Bool {
        guard previewContent.isPresented, let dependencies,
              previewOriginIsCurrent(), let originID = previewContent.originID else {
            return pane != nil || splitPane != nil
        }
        let session = previewContent.session
        let requested = requestedID ?? originID
        let existingOtherID: String? = {
            guard let split = splitWorkspace, let slot = splitPreviewOriginSlot else { return nil }
            let otherID = slot == split.sourceSlot
                ? split.secondaryConversationID : split.sourceConversationID
            return requested == otherID ? otherID : nil
        }()
        // A Conversation already open in the other Pane has one live owner.
        // Restore the Lift origin and activate that owner instead of mounting a duplicate.
        let id = existingOtherID == nil || !previewRestoresSplit ? requested : originID
        if let prepared = previewContent.prepared {
            if prepared.pane.conversationID == id {
                splitExistingOtherReturnID = existingOtherID
                return true
            }
            cancelPreviewReturn()
        }
        if previewContent.isPreparing, previewContent.preparationTargetID != id { cancelPreviewReturn() }
        guard !previewContent.isPreparing else { return false }
        splitExistingOtherReturnID = existingOtherID
        let preparation = previewContent.beginPreparation(targetID: id)
        if !previewRestoresSplit {
            let existing = pane?.conversationID == id ? pane : splitPane?.conversationID == id ? splitPane : nil
            let bridge = pane?.conversationID == id ? actionBridge : splitActionBridge
            if let existing, let bridge {
                do {
                    let lifecycle = try dependencies.store.conversationLifecycle(id: id)
                    guard lifecycle == .visible || (lifecycle == nil
                        && existing.session === sessions.uncommittedSession(for: id)) else {
                        throw PersistenceError.conversationNotFound(id)
                    }
                    borrowedPreviewOwner = true
                    previewContent.ready((bridge: bridge, pane: existing), id: preparation)
                    return true
                } catch {
                    previewContent.failed(preparation)
                    return false
                }
            }
        }
        // Structural Run/Tool changes may invalidate a read. Text growth is replayed.
        // Retry a finite number of times; failure
        // leaves the Preview and its logical state intact for an explicit retry.
        for _ in 0..<3 {
            let ticket = router.beginPanePreparation(for: id)
            do {
                let history = try await router.historyPreparation.prepare(id: id, store: dependencies.store)
                guard !Task.isCancelled, previewOriginIsCurrent(),
                      router === dependencies.router, previewContent.accepts(preparation) else {
                    dependencies.router.cancelPanePreparation(for: id, ticket: ticket)
                    previewContent.cancelPreparation(for: preparation)
                    return false
                }
                guard router.acceptsPanePreparation(for: id, ticket: ticket) else { continue }
                // Missing durable rows require a positively retained presentation owner.
                let warmOwner = sessions.uncommittedSession(for: id)
                guard history.snapshot.conversation?.lifecycle == .visible
                    || (history.snapshot.conversation == nil && (id == originID || warmOwner != nil)) else {
                    throw PersistenceError.conversationNotFound(id)
                }
                let wiring = try ConversationPaneFactory(sessions: sessions).makePane(
                    id: id, initialTimeline: history.timeline, dependencies: dependencies, target: target,
                    snapshot: history.snapshot,
                    onTargetFailure: { [weak self] failure, failedTarget in
                        self?.targetBecameUnavailable(failure, for: failedTarget, conversationID: id)
                    })
                guard (id != originID || (session.map { wiring.pane.session === $0 } ?? false)),
                      (warmOwner == nil || wiring.pane.session === warmOwner),
                      router.registerPreparedPane(wiring.pane, ticket: ticket) else { continue }
                // Receive durable Runtime events while still hidden behind Preview.
                previewContent.ready(wiring, id: preparation)
                return true
            } catch {
                dependencies.router.cancelPanePreparation(for: id, ticket: ticket)
                if Task.isCancelled || (error is CancellationError) {
                    previewContent.cancelPreparation(for: preparation)
                } else {
                    previewContent.failed(preparation)
                }
                return false
            }
        }
        router.cancelPanePreparation(for: id)
        previewContent.failed(preparation)
        return false
    }

    func commitPreviewReturn(openingSplitAt newSplitSlot: SplitDropSlot? = nil) -> Bool {
        guard previewContent.isPresented, let prepared = previewContent.prepared,
              previewOriginIsCurrent(), let originID = previewContent.originID,
              prepared.pane.conversationID == previewContent.preparationTargetID else { return false }
        let targetID = prepared.pane.conversationID
        if previewRestoresSplit, let split = splitWorkspace, let slot = splitPreviewOriginSlot {
            let otherID = slot == split.sourceSlot
                ? split.secondaryConversationID : split.sourceConversationID
            guard targetID != otherID else { return false }
            let selectExistingOther = splitExistingOtherReturnID != nil
                && splitExistingOtherReturnID == otherID && targetID == originID
            if targetID != originID, let outgoing = previewContent.session {
                rememberSession(outgoing, id: originID, retainUncommitted: true)
            }
            if let otherID {
                guard sessions.activate(prepared.pane.session, alongside: otherID,
                    isRuntimeProtected: router.hasActiveRun(for:)) else { return false }
            } else {
                commitSession(prepared.pane.session)
            }
            previewHandoffID = targetID
            if slot == split.sourceSlot {
                var updated = SplitWorkspaceState(sourceConversationID: targetID,
                                                  sourceSlot: split.sourceSlot, preserving: split)
                if let secondaryID = split.secondaryConversationID {
                    guard updated.occupy(secondaryID) else { return false }
                }
                updated.select(selectExistingOther ? split.emptySlot : slot)
                splitWorkspace = updated
                conversationID = targetID
                pane = prepared.pane
                actionBridge = prepared.bridge
                sendAvailability = prepared.pane.composer.sendAvailability
                targetMessage = sendAvailability.message
            } else {
                var updated = split
                guard updated.occupy(targetID) else { return false }
                if selectExistingOther { updated.select(split.sourceSlot) }
                splitWorkspace = updated
                splitPane = prepared.pane
                splitActionBridge = prepared.bridge
            }
            previewContent.finish()
            splitPreviewOriginSlot = nil
            splitExistingOtherReturnID = nil
            borrowedPreviewOwner = false
            previewSurfaceSlot = nil
            cardActions?.reset()
            return true
        }
        if let outgoing = previewContent.session, outgoing.conversationID != targetID,
           !deletedSplitIDs.contains(outgoing.conversationID) {
            rememberSession(outgoing, id: outgoing.conversationID, retainUncommitted: true)
        }
        for outgoing in [pane, splitPane].compactMap({ $0 }) where outgoing.conversationID != targetID {
            if !deletedSplitIDs.contains(outgoing.conversationID) {
                rememberSession(outgoing.session, id: outgoing.conversationID, retainUncommitted: true)
            }
            router.unregisterPane(for: outgoing.conversationID)
        }
        // Keep the native host which performed Lift, including a secondary host
        // promoted to Single. Its content owner changes; its animator does not.
        sourceSurfaceSlot = previewSurfaceSlot ?? sourceSurfaceSlot
        splitPane = nil
        splitActionBridge = nil
        splitWorkspace = newSplitSlot.map { SplitWorkspaceState(sourceConversationID: targetID, sourceSlot: $0) }
        deletedSplitIDs = []
        previewHandoffID = targetID
        conversationID = targetID
        pane = prepared.pane
        actionBridge = prepared.bridge
        commitSession(prepared.pane.session)
        sendAvailability = prepared.pane.composer.sendAvailability
        targetMessage = sendAvailability.message
        previewContent.finish()
        splitPreviewOriginSlot = nil
        splitExistingOtherReturnID = nil
        borrowedPreviewOwner = false
        previewSurfaceSlot = nil
        cardActions?.reset()
        return true
    }

    func cancelPreviewReturn() {
        splitExistingOtherReturnID = nil
        if previewContent.isPreparing { router.historyPreparation.cancel() }
        if let prepared = previewContent.prepared, !borrowedPreviewOwner {
            router.unregisterPane(for: prepared.pane.conversationID)
        }
        if let targetID = previewContent.preparationTargetID, !borrowedPreviewOwner {
            router.cancelPanePreparation(for: targetID)
        }
        borrowedPreviewOwner = false
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
    private var cardActions: AppSpaceConversationActions?
    private(set) var cardDeletion: AppSpaceConversationDeletion?
    @ObservationIgnored private var startedAssembly = false
    @ObservationIgnored private var backgroundedAtInProcess: Date?
    @ObservationIgnored private let sessions = ConversationSessionStore()
    @ObservationIgnored private var configurationRefreshIDs: [ProviderInstanceID: UUID] = [:]
    @ObservationIgnored private var navigationID = UUID()
    @ObservationIgnored private var openTicket: (conversationID: String, ticket: UUID)?
    @ObservationIgnored private var splitSelectionID = UUID()
    @ObservationIgnored private var splitOpenTicket: (conversationID: String, ticket: UUID)?
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
        appearance = AppearanceSettings(defaults: userDefaults)
        modelMenus = ModelMenuPreferences(defaults: userDefaults)
        self.router = RunEventRouter()
    }

    init(
        dependencies: AppAssembly.Dependencies,
        userDefaults: UserDefaults
    ) {
        self.userDefaults = userDefaults
        appearance = AppearanceSettings(defaults: userDefaults)
        modelMenus = ModelMenuPreferences(defaults: userDefaults)
        self.dependencies = dependencies
        self.cardActions = AppSpaceConversationActions(store: dependencies.store)
        self.router = dependencies.router
        installCardDeletion(dependencies)
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
        closeSplit()
        dependencies = nil
        cardActions = nil
        cardDeletion = nil
        sessions.removeAll()
        pane = nil
        actionBridge = nil
        target = nil
        targetMessage = nil
        sendAvailability = .unconfigured
        recentConversations = []
        recentListLoadError = nil
        recentOpenFailure = nil
        providerSetup = nil
        router = RunEventRouter()

        do {
            let assembled = try AppAssembly.assemble(router: router)
            dependencies = assembled
            cardActions = AppSpaceConversationActions(store: assembled.store)
            installCardDeletion(assembled)
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
        if splitWorkspace != nil, !previewContent.isPresented {
            _ = replaceSourceWithNewInSplit()
            return
        }
        closeSplit()
        cardActions?.reset()
        navigationID = UUID()
        recentOpenFailure = nil
        router.historyPreparation.cancel()
        launchRestorationTask?.cancel()
        rememberCurrentSession(retainUncommitted: true)
        cancelPreviewReturn()
        previewContent.finish()
        router.unregisterPane(for: conversationID)
        pane = nil
        actionBridge = nil
        conversationID = UUID().uuidString
        installPaneIfReady()
        refreshRecentConversations()
    }

    @discardableResult
    private func replaceSourceWithNewInSplit() -> Bool {
        guard let split = splitWorkspace, split.sourceConversationID == conversationID,
              let outgoing = pane, let dependencies else { return false }
        let id = UUID().uuidString
        do {
            let wiring = try ConversationPaneFactory(sessions: sessions).makePane(
                id: id, initialTimeline: ConversationTimelineProjection(conversationID: id, turns: []),
                dependencies: dependencies, target: target,
                onTargetFailure: { [weak self] failure, failedTarget in
                    self?.targetBecameUnavailable(failure, for: failedTarget, conversationID: id)
                })
            guard router.registerPane(wiring.pane) else { throw AppTargetFailure.configurationUnavailable }
            rememberSession(outgoing.session, id: conversationID, retainUncommitted: true)
            let activated: Bool
            if let secondaryID = split.secondaryConversationID {
                activated = sessions.activate(wiring.pane.session, alongside: secondaryID,
                                              isRuntimeProtected: router.hasActiveRun(for:))
            } else {
                sessions.activate(wiring.pane.session, isRuntimeProtected: router.hasActiveRun(for:))
                activated = true
            }
            guard activated else {
                router.unregisterPane(for: id)
                throw AppTargetFailure.configurationUnavailable
            }
            navigationID = UUID()
            launchRestorationTask?.cancel()
            splitSelectionID = UUID()
            if let splitOpenTicket {
                router.cancelPanePreparation(for: splitOpenTicket.conversationID,
                                             ticket: splitOpenTicket.ticket)
                self.splitOpenTicket = nil
            }
            router.unregisterPane(for: conversationID)
            var updated = SplitWorkspaceState(sourceConversationID: id, sourceSlot: split.sourceSlot, preserving: split)
            if let secondaryID = split.secondaryConversationID { _ = updated.occupy(secondaryID) }
            updated.select(split.sourceSlot)
            splitWorkspace = updated
            conversationID = id
            pane = wiring.pane
            actionBridge = wiring.bridge
            sendAvailability = wiring.pane.composer.sendAvailability
            targetMessage = sendAvailability.message
            cardActions?.reset()
            recentOpenFailure = nil
            refreshRecentConversations()
            return true
        } catch {
            splitOpenError = "无法创建会话，请重试。"
            return false
        }
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
        cardDeletion?.recoverPending()
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

    private func installCardDeletion(_ dependencies: AppAssembly.Dependencies) {
        let runtime = dependencies.runtime
        let owner = AppSpaceConversationDeletion(store: dependencies.store,
            stopRun: { id in try await runtime.stop(runID: id) },
            waitForRun: { id in try await runtime.waitForCompletion(runID: id) },
            now: { Date() },
            onFinalized: { [weak self] id in
                self?.detachDeletedSplitPane(id: id)
                if self?.previewContent.preparationTargetID == id {
                    self?.cancelPreviewReturn()
                }
                self?.sessions.remove(conversationID: id)
                self?.previewContent.discardFinalizedOriginSession(id: id)
            })
        cardDeletion = owner
        owner.recoverPending()
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

    var isCurrentConversationVisible: Bool {
        guard let store = dependencies?.store else { return false }
        return (try? store.conversationLifecycle(id: conversationID)) == .visible
    }

    private func rememberCurrentSession(retainUncommitted: Bool = false) {
        guard let session = pane?.session ?? previewContent.session else { return }
        rememberSession(session, id: conversationID, retainUncommitted: retainUncommitted)
    }

    private func rememberSession(_ session: ConversationSession, id: String,
                                 retainUncommitted: Bool) {
        guard let store = dependencies?.store else { return }
        do {
            guard let summary = try store.conversationSummaryWindow(ids: [id]).first else {
                if retainUncommitted, try store.conversationLifecycle(id: id) == nil {
                    sessions.retain(session, reconstruction: .uncommitted)
                } else {
                    sessions.remove(conversationID: id)
                }
                return
            }
            // Re-read the latest persisted Parent choice. An initial choice can
            // become stale after another Send, even if the user switches back to it.
            let configuration: ConversationComposerConfiguration?
            if let instanceID = summary.providerInstanceID, let modelID = summary.modelID {
                configuration = ConversationComposerConfiguration(providerInstanceID: instanceID, modelID: modelID)
            } else if summary.runProjection == nil,
                      let binding = try store.conversationInitialBinding(id: id),
                      let instanceID = binding.providerInstanceID, let modelID = binding.modelID {
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
        sessions.activate(session, isRuntimeProtected: router.hasActiveRun(for:))
        sessions.evictIfNeeded(isRuntimeProtected: router.hasActiveRun(for:))
    }

    func refreshRecentConversations() {
        guard let store = dependencies?.store else { return }
        do {
            let page = try store.conversationSummaryPage()
            recentConversations = page.items.map { RecentConversationSummary(id: $0.id, title: $0.title,
                previewStatus: $0.contentUnavailable ? .contentUnavailable : .ready) }
            recentCursor = page.nextCursor
            recentListLoadError = nil
            recentFailureWasNextPage = false
        } catch {
            // Preserve the last readable page and its cursor so failure remains retryable.
            recentFailureWasNextPage = false
            recentListLoadError = "会话列表读取失败，请重试。"
        }
    }

    @discardableResult
    func openConversation(id: String, presentation: ConversationOpenPresentation = .preserved) async -> Bool {
        guard let dependencies, !Task.isCancelled else { return false }
        if presentation == .resting, pane?.composer.isComposing == true { return false }
        if let split = splitWorkspace, split.secondaryConversationID == id,
           let secondary = splitPane, secondary.conversationID == id {
            do {
                let lifecycle = try dependencies.store.conversationLifecycle(id: id)
                guard lifecycle == .visible || (lifecycle == nil
                    && secondary.session === sessions.uncommittedSession(for: id)) else { return false }
                selectSplitSlot(split.emptySlot)
                if presentation == .resting { secondary.composer.draft.presentationState = .resting }
                recentOpenFailure = nil
                return true
            } catch {
                recentOpenFailure = RecentConversationOpenFailure(conversationID: id)
                return false
            }
        }
        if id == conversationID {
            if pane != nil {
                do {
                    let lifecycle = try dependencies.store.conversationLifecycle(id: id)
                    let visible = lifecycle == .visible || (lifecycle == nil
                        && pane?.session === sessions.uncommittedSession(for: id))
                    if visible {
                        if presentation == .resting { pane?.composer.draft.presentationState = .resting }
                        recentOpenFailure = nil
                        if let split = splitWorkspace { selectSplitSlot(split.sourceSlot) }
                    }
                    return visible
                } catch {
                    recentOpenFailure = RecentConversationOpenFailure(conversationID: id)
                    return false
                }
            }
            if previewContent.prepared?.pane.conversationID == id {
                let committed = commitPreviewReturn()
                if committed { recentOpenFailure = nil }
                return committed
            }
        }

        cancelPreviewReturn()
        let navigation = UUID()
        let replacingSplit = previewContent.isPresented ? nil : splitWorkspace
        navigationID = navigation
        if let openTicket {
            router.cancelPanePreparation(for: openTicket.conversationID, ticket: openTicket.ticket)
        }
        let ticket = router.beginPanePreparation(for: id)
        openTicket = (id, ticket)
        defer {
            dependencies.router.cancelPanePreparation(for: id, ticket: ticket)
            if openTicket?.ticket == ticket { openTicket = nil }
        }
        do {
            let history = try await router.historyPreparation.prepare(id: id, store: dependencies.store)
            let warmOwner = sessions.uncommittedSession(for: id)
            guard !Task.isCancelled, navigationID == navigation, router === dependencies.router,
                  replacingSplit == nil || (splitWorkspace?.arrangementID == replacingSplit?.arrangementID
                    && splitWorkspace?.sourceConversationID == replacingSplit?.sourceConversationID
                    && splitWorkspace?.secondaryConversationID == replacingSplit?.secondaryConversationID),
                  history.snapshot.conversation?.lifecycle == .visible
                    || (history.snapshot.conversation == nil && warmOwner != nil) else { return false }
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
            // History was read asynchronously. Recheck durable visibility at
            // registration, after synchronous wiring has resolved its bindings.
            let lifecycle = try dependencies.store.conversationLifecycle(id: id)
            guard lifecycle == .visible || (lifecycle == nil && warmOwner != nil),
                  presentation != .resting || !wiring.pane.composer.isComposing,
                  (warmOwner == nil || wiring.pane.session === warmOwner),
                  dependencies.router.registerPreparedPane(wiring.pane, ticket: ticket) else { return false }

            if let otherID = replacingSplit?.secondaryConversationID {
                guard sessions.activate(wiring.pane.session, alongside: otherID,
                                        isRuntimeProtected: router.hasActiveRun(for:)) else {
                    router.unregisterPane(for: id)
                    recentOpenFailure = RecentConversationOpenFailure(conversationID: id)
                    return false
                }
            }

            // Keep the outgoing pane intact until the replacement has loaded and registered.
            if presentation == .resting { wiring.pane.composer.draft.presentationState = .resting }
            rememberCurrentSession(retainUncommitted: true)
            cancelPreviewReturn()
            previewContent.finish()
            cardActions?.reset()
            let outgoingConversationID = conversationID
            if outgoingConversationID != id { router.unregisterPane(for: outgoingConversationID) }
            if replacingSplit != nil, let split = splitWorkspace {
                // History preparation yields: retain the ratio most recently
                // measured by this same live arrangement, not its old snapshot.
                cancelSplitSelection()
                var updated = SplitWorkspaceState(sourceConversationID: id, sourceSlot: split.sourceSlot, preserving: split)
                if let otherID = split.secondaryConversationID { _ = updated.occupy(otherID) }
                updated.select(split.sourceSlot)
                splitWorkspace = updated
            } else {
                closeSplit()
            }
            conversationID = id
            actionBridge = wiring.bridge
            pane = wiring.pane
            if replacingSplit?.secondaryConversationID == nil { commitSession(wiring.pane.session) }
            sendAvailability = wiring.pane.composer.sendAvailability
            targetMessage = sendAvailability.message
            recentOpenFailure = nil
            return true
        } catch {
            // Cancelled or obsolete navigation must not replace the current action's feedback.
            if !Task.isCancelled, !(error is CancellationError),
               navigationID == navigation, router === dependencies.router {
                recentOpenFailure = RecentConversationOpenFailure(conversationID: id)
            }
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
        guard pane != nil else {
            installPaneIfReady()
            return
        }
        do {
            _ = try initializeConversationConfiguration(savedTarget, id: conversationID)
        } catch {
            targetMessage = AppTargetFailure.persistenceUnavailable.message
        }
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

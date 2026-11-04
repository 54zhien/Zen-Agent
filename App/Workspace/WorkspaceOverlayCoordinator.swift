import Foundation
import Observation

@MainActor
@Observable
final class WorkspaceOverlayCoordinator {
    enum SearchPresentation: Equatable { case fullText, semantic }

    let search: ConversationSearchModel
    let semanticSearch: ConversationSemanticSearchModel
    private(set) var searchPresentation: SearchPresentation = .fullText
    private(set) var files: FilesWorkspaceModel?
    private(set) var settings: SettingsWorkspaceModel?
    var availableRoutes: Set<WorkspaceOverlayRoute> {
        var routes: Set<WorkspaceOverlayRoute> = [.search]
        if shell?.workspaceStore != nil { routes.insert(.settings) }
        if shell?.workspaceFilesAvailable == true { routes.insert(.files) }
        return routes
    }
    @ObservationIgnored private weak var shell: AppShellModel?
    @ObservationIgnored private weak var navigation: WorkspaceNavigationState?
    @ObservationIgnored private var focus: ComposerOverlayFocus?
    @ObservationIgnored private var pendingSidebarFocus: ComposerOverlayFocus?
    @ObservationIgnored private var dismissingSettingsID: UUID?

    init(store: PersistenceStore, shell: AppShellModel, navigation: WorkspaceNavigationState) {
        search = ConversationSearchModel(store: store)
        semanticSearch = shell.makeConversationSemanticSearchModel()
        self.shell = shell; self.navigation = navigation
    }

    func prepareFocusForSidebarDismissal(captureFocus: () -> ComposerOverlayFocus?) {
        guard let navigation, navigation.overlay == nil, !navigation.isOpen,
              !navigation.isDragging, navigation.settlementID == nil else { return }
        if let pendingSidebarFocus {
            guard !pendingSidebarFocus.isValid else { return }
            pendingSidebarFocus.cancel()
            self.pendingSidebarFocus = nil
        }
        guard let captured = captureFocus() else { return }
        guard captured.isValid else { captured.cancel(); return }
        captured.markAsSidebarDismissalIntent()
        pendingSidebarFocus = captured
    }

    func sidebarDidClose() {
        discardPendingSidebarFocus()
    }

    func enter(_ route: WorkspaceOverlayRoute, eligible: Bool, captureFocus: () -> ComposerOverlayFocus?) {
        guard dismissingSettingsID == nil, let navigation, availableRoutes.contains(route) else { return }
        let catalog = route == .files ? shell?.makeFilesWorkspaceModel() : nil
        let settingsModel = route == .settings ? shell?.makeSettingsModel(configureNewID: shell?.currentSettingsNewID) : nil
        if route == .files, catalog == nil { return }
        if route == .settings, settingsModel == nil { return }
        let currentFocus = captureFocus()
        let captured: ComposerOverlayFocus?
        if route == .search || route == .files {
            if let currentFocus, currentFocus.isValid {
                discardPendingSidebarFocus()
                captured = currentFocus
            } else {
                currentFocus?.cancel()
                captured = takePendingSidebarFocus()
            }
        } else {
            discardPendingSidebarFocus()
            if let currentFocus, currentFocus.isValid {
                captured = currentFocus
            } else {
                currentFocus?.cancel()
                captured = nil
            }
        }
        guard navigation.present(route, available: true, eligible: eligible) else {
            captured?.cancel()
            discardPendingSidebarFocus()
            return
        }
        focus?.cancel(); focus = captured
        if route == .search {
            searchPresentation = .fullText
            search.query = ""
            semanticSearch.query = ""
        }
        files = catalog
        settings = settingsModel
    }

    func openFilesFromSettings(expectedID: UUID) {
        guard let navigation, let catalog = shell?.makeFilesWorkspaceModel(),
              navigation.replaceSettingsWithFiles(expectedID: expectedID) else { return }
        dismissingSettingsID = expectedID
        files = catalog
        // The original Conversation capability stays owned until Files closes.
    }

    func close(expectedID: UUID? = nil) {
        guard navigation?.overlay != nil,
              expectedID == nil || navigation?.overlayID == expectedID else { return }
        discardPendingSidebarFocus()
        if navigation?.overlay == .settings {
            dismissingSettingsID = navigation?.overlayID
            navigation?.dismissOverlay()
            return
        }
        search.invalidate(); semanticSearch.invalidate()
        files?.invalidate(); files = nil
        navigation?.dismissOverlay()
        // A Files route can close while the originating Settings sheet is
        // still retiring. Its original focus waits for that same dismissal.
        guard dismissingSettingsID == nil else { return }
        settings?.invalidate(); settings = nil
        let captured = focus; focus = nil
        captured?.restore()
    }

    func settingsDidDismiss(expectedID: UUID) {
        guard dismissingSettingsID == expectedID else { return }
        dismissingSettingsID = nil
        settings?.invalidate(); settings = nil
        guard navigation?.overlay == nil else { return }
        let captured = focus; focus = nil
        captured?.restore()
    }

    @discardableResult
    func select(_ id: String) -> Task<Void, Never> {
        search.select(id, open: { [weak shell] id in
            await shell?.openActivePaneConversation(id: id) ?? false
        }, onSuccess: { [weak self] in
            self?.focus?.cancel(); self?.focus = nil
            self?.discardPendingSidebarFocus()
            self?.navigation?.dismissOverlay()
        })
    }

    func showSemanticSearch(expectedID: UUID) {
        guard navigation?.overlay == .search, navigation?.overlayID == expectedID else { return }
        search.invalidate()
        searchPresentation = .semantic
    }

    func showFullTextSearch(expectedID: UUID) {
        guard navigation?.overlay == .search, navigation?.overlayID == expectedID else { return }
        semanticSearch.invalidate()
        searchPresentation = .fullText
    }

    @discardableResult
    func selectSemanticResult(_ id: String) -> Task<Void, Never> {
        semanticSearch.select(id, open: { [weak shell] id in
            await shell?.openActivePaneConversation(id: id) ?? false
        }, onSuccess: { [weak self] in
            self?.focus?.cancel()
            self?.navigation?.dismissOverlay()
        })
    }

    func reset() {
        dismissingSettingsID = nil
        search.invalidate(); semanticSearch.invalidate(); files?.invalidate(); files = nil
        settings?.invalidate(); settings = nil
        discardPendingSidebarFocus()
        focus?.cancel(); focus = nil
    }

    private func takePendingSidebarFocus() -> ComposerOverlayFocus? {
        let captured = pendingSidebarFocus
        pendingSidebarFocus = nil
        guard let captured, captured.isValid else {
            captured?.cancel()
            return nil
        }
        return captured
    }

    private func discardPendingSidebarFocus() {
        let captured = pendingSidebarFocus
        pendingSidebarFocus = nil
        captured?.cancel()
    }
}

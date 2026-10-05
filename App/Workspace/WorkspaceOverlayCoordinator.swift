import Foundation
import Observation

@MainActor
@Observable
final class WorkspaceOverlayCoordinator {
    let search: ConversationSearchModel
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

    init(store: PersistenceStore, shell: AppShellModel, navigation: WorkspaceNavigationState) {
        search = ConversationSearchModel(store: store)
        self.shell = shell; self.navigation = navigation
    }

    func enter(_ route: WorkspaceOverlayRoute, eligible: Bool, captureFocus: () -> ComposerOverlayFocus?) {
        guard let navigation, availableRoutes.contains(route) else { return }
        let catalog = route == .files ? shell?.makeFilesWorkspaceModel() : nil
        let settingsModel = route == .settings ? shell?.makeSettingsModel() : nil
        if route == .files, catalog == nil { return }
        if route == .settings, settingsModel == nil { return }
        let captured = captureFocus()
        guard navigation.present(route, available: true, eligible: eligible) else { captured?.cancel(); return }
        focus?.cancel(); focus = captured
        if route == .search { search.query = "" }
        files = catalog
        settings = settingsModel
    }

    func enterNewSettings(id: String, eligible: Bool, captureFocus: () -> ComposerOverlayFocus?) {
        guard eligible, shell?.currentSettingsNewID == id, let navigation,
              let model = shell?.makeSettingsModel(configureNewID: id) else { return }
        let captured = captureFocus()
        guard navigation.presentNewSettings(eligible: eligible) else { captured?.cancel(); return }
        focus?.cancel(); focus = captured; settings = model
    }

    func openFilesFromSettings(expectedID: UUID) {
        guard let navigation, let catalog = shell?.makeFilesWorkspaceModel(),
              navigation.replaceSettingsWithFiles(expectedID: expectedID) else { return }
        settings?.invalidate(); settings = nil; files = catalog
        // The original Conversation capability stays owned until Files closes.
    }

    func close(expectedID: UUID? = nil) {
        guard navigation?.overlay != nil,
              expectedID == nil || navigation?.overlayID == expectedID else { return }
        search.invalidate()
        files?.invalidate(); files = nil
        settings?.invalidate(); settings = nil
        navigation?.dismissOverlay()
        let captured = focus; focus = nil
        captured?.restore()
    }

    @discardableResult
    func select(_ id: String) -> Task<Void, Never> {
        search.select(id, open: { [weak shell] id in
            await shell?.openActivePaneConversation(id: id) ?? false
        }, onSuccess: { [weak self] in
            self?.focus?.cancel()
            self?.navigation?.dismissOverlay()
        })
    }

    func reset() {
        search.invalidate(); files?.invalidate(); files = nil
        settings?.invalidate(); settings = nil
        focus?.cancel(); focus = nil
    }
}

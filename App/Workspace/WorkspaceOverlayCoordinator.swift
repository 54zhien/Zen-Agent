import Foundation
import Observation

@MainActor
@Observable
final class WorkspaceOverlayCoordinator {
    let search: ConversationSearchModel
    private(set) var files: FilesWorkspaceModel?
    var availableRoutes: Set<WorkspaceOverlayRoute> {
        var routes: Set<WorkspaceOverlayRoute> = [.search]
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
        if route == .files, catalog == nil { return }
        let captured = captureFocus()
        guard navigation.present(route, available: true, eligible: eligible) else { captured?.cancel(); return }
        focus?.cancel(); focus = captured
        if route == .search { search.query = "" }
        files = catalog
    }

    func close(expectedID: UUID? = nil) {
        guard navigation?.overlay != nil,
              expectedID == nil || navigation?.overlayID == expectedID else { return }
        search.invalidate()
        files?.invalidate(); files = nil
        navigation?.dismissOverlay()
        let captured = focus; focus = nil
        captured?.restore()
    }

    @discardableResult
    func select(_ id: String) -> Task<Void, Never> {
        search.select(id, open: { [weak shell] id in
            await shell?.openConversation(id: id, presentation: .resting) ?? false
        }, onSuccess: { [weak self] in
            self?.focus?.cancel()
            self?.navigation?.dismissOverlay()
        })
    }

    func reset() {
        search.invalidate(); files?.invalidate(); files = nil
        focus?.cancel(); focus = nil
    }
}

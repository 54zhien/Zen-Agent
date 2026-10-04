import Observation

@MainActor
@Observable
final class WorkspaceOverlayCoordinator {
    let search: ConversationSearchModel
    @ObservationIgnored private weak var shell: AppShellModel?
    @ObservationIgnored private weak var navigation: WorkspaceNavigationState?
    @ObservationIgnored private var focus: ComposerOverlayFocus?

    init(store: PersistenceStore, shell: AppShellModel, navigation: WorkspaceNavigationState) {
        search = ConversationSearchModel(store: store)
        self.shell = shell; self.navigation = navigation
    }

    func enter(_ route: WorkspaceOverlayRoute, eligible: Bool, captureFocus: () -> ComposerOverlayFocus?) {
        guard let navigation, route == .search else { return }
        let captured = captureFocus()
        guard navigation.present(route, available: true, eligible: eligible) else { captured?.cancel(); return }
        focus?.cancel(); focus = captured
        search.query = ""
    }

    func close() {
        guard navigation?.overlay != nil else { return }
        search.invalidate()
        navigation?.dismissOverlay()
        focus?.restore()
    }

    func select(_ id: String) {
        search.select(id, open: { [weak shell] id in
            await shell?.openConversation(id: id, presentation: .resting) ?? false
        }, onSuccess: { [weak self] in
            self?.focus?.cancel()
            self?.navigation?.dismissOverlay()
        })
    }

    func reset() {
        search.invalidate(); focus?.cancel(); focus = nil
    }
}

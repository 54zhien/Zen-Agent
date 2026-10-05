import SwiftUI

/// Composition only: the retained native Surface owns its own translation.
@MainActor
struct WorkspaceNavigationView<Content: View>: View {
    let state: WorkspaceNavigationState
    let context: () -> WorkspaceSidebarNativeContext?
    let spatiallyAvailable: Bool
    let windowInsets: EdgeInsets
    let content: Content
    let model: AppShellModel?
    let captureFocus: () -> ComposerOverlayFocus?
    let canConfigureNew: (String) -> Bool
    @State private var overlays: WorkspaceOverlayCoordinator?
    @Environment(\.layoutDirection) private var direction
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(state: WorkspaceNavigationState, model: AppShellModel? = nil,
         captureFocus: @escaping () -> ComposerOverlayFocus? = { nil },
         canConfigureNew: @escaping (String) -> Bool = { _ in false }, spatiallyAvailable: Bool,
         windowInsets: EdgeInsets = EdgeInsets(),
         context: @escaping () -> WorkspaceSidebarNativeContext?, @ViewBuilder content: () -> Content) {
        self.state = state
        self.model = model; self.captureFocus = captureFocus
        self.canConfigureNew = canConfigureNew
        self.spatiallyAvailable = spatiallyAvailable
        self.windowInsets = windowInsets
        self.context = context
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            // The full viewport deliberately ignores container safe areas. Use
            // the actual scene Window insets for controls, not this reader's zeroes.
            let travel = min(geometry.size.width, 60 + windowInsets.leading)
            ZStack(alignment: .leading) {
                if state.progress > 0 {
                    SidebarRailView(availableRoutes: !state.isDragging && state.settlementID == nil ? overlays?.availableRoutes ?? [] : [],
                        conversationActions: !state.isDragging && state.settlementID == nil ? state.conversationActions : [],
                        onAction: state.perform,
                        onSelect: { route in
                            overlays?.enter(route, eligible: context()?.allowsOpening == true, captureFocus: captureFocus)
                        })
                        .padding(.leading, windowInsets.leading)
                        .padding(.top, windowInsets.top)
                        .padding(.bottom, windowInsets.bottom)
                        .frame(width: travel, height: geometry.size.height)
                        .background(Color(white: 0.035))
                        // The retained content still occupies the full viewport
                        // in SwiftUI. Once exposed and settled, Rail controls must
                        // precede that transparent hit region within this strip.
                        .zIndex(state.isOpen && !state.isDragging && state.settlementID == nil ? 1 : 0)
                }
                content
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .accessibilityHidden(state.overlay != nil)
                    .accessibilityElement(children: .contain)
                    .accessibilityActions {
                        if spatiallyAvailable, !state.blocksLift {
                            Button("打开侧边栏") {
                                _ = state.openSidebar(eligible: context()?.allowsOpening == true)
                            }
                        }
                        if state.isOpen {
                            Button("关闭侧边栏") { state.closeSidebar() }
                        }
                    }
                if state.overlay == .search, let overlays, let id = state.overlayID {
                    ConversationSearchView(model: overlays.search, onClose: { overlays.close(expectedID: id) },
                        onSelect: { id in _ = overlays.select(id) })
                        .id(id)
                        .padding(.top, windowInsets.top)
                        .transition(.opacity).zIndex(100)
                }
                if state.overlay == .files, let overlays, let catalog = overlays.files, let id = state.overlayID {
                    FilesWorkspaceView(model: catalog, onClose: { overlays.close(expectedID: id) })
                        .id(id)
                        .padding(.top, windowInsets.top)
                        .transition(.opacity).zIndex(100)
                }
                if state.overlay == .settings, let overlays, let settings = overlays.settings, let id = state.overlayID {
                    SettingsWorkspaceView(model: settings, onClose: { overlays.close(expectedID: id) },
                        onFiles: { overlays.openFilesFromSettings(expectedID: id) })
                        .id(id).padding(.top, windowInsets.top)
                        .transition(.opacity).zIndex(100)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: state.overlay)
            .background(Color(white: 0.035))
            .background(WorkspaceSidebarGestureBridge(state: state, travel: travel,
                isRightToLeft: direction == .rightToLeft, context: context))
        }
        .ignoresSafeArea(.container)
        .onAppear {
            if overlays == nil, let model, let store = model.workspaceStore {
                overlays = WorkspaceOverlayCoordinator(store: store, shell: model, navigation: state)
            }
            state.onReset = { [weak overlays] in overlays?.reset() }
            state.onConfigureNew = { [weak overlays] id in
                overlays?.enterNewSettings(id: id, eligible: canConfigureNew(id), captureFocus: captureFocus)
            }
        }
        .onDisappear { overlays?.reset(); state.onReset = nil; state.onConfigureNew = nil }
    }
}

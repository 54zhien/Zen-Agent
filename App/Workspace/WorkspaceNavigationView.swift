import SwiftUI

@MainActor
private struct SidebarRailProgressLayer: View {
    let state: WorkspaceNavigationState
    let availableRoutes: Set<WorkspaceOverlayRoute>
    let layout: SidebarRailLayout
    let travel: CGFloat
    let height: CGFloat
    let onSelect: (WorkspaceOverlayRoute) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let progress = CGFloat(state.progress)
        let isDragging = state.isDragging
        let settlementID = state.settlementID
        let isInteractive = state.isOpen && !isDragging && settlementID == nil

        if progress > 0 || settlementID != nil {
            SidebarRailView(
                availableRoutes: isInteractive ? availableRoutes : [],
                conversationActions: isInteractive ? state.conversationActions : [],
                onAction: state.perform,
                onSelect: onSelect
            )
            .padding(.leading, layout.leading)
            .padding(.trailing, layout.leading)
            .padding(.top, layout.top)
            .padding(.bottom, layout.bottom)
            .frame(width: travel, height: height)
            // The native Surface covers the full viewport; reveal only the exposed
            // portion of the rail above its hit region.
            .mask(alignment: .leading) {
                Rectangle().frame(width: travel * progress)
            }
            .opacity(SidebarProgressPresentation.opacity(forProgress: Double(progress)))
            .animation(reduceMotion || isDragging ? nil : .easeOut(duration: 0.22), value: progress)
            .allowsHitTesting(isInteractive)
            .accessibilityHidden(!isInteractive)
            .zIndex(1)
        }
    }
}

/// Composition only: the retained native Surface owns its own translation.
@MainActor
struct WorkspaceNavigationView<Content: View>: View {
    let state: WorkspaceNavigationState
    let context: () -> WorkspaceSidebarNativeContext?
    let spatiallyAvailable: Bool
    let windowInsets: EdgeInsets
    let windowCornerRadius: CGFloat
    let keepsFullConversationViewport: Bool
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
         windowInsets: EdgeInsets = EdgeInsets(), windowCornerRadius: CGFloat = 0,
         keepsFullConversationViewport: Bool = false,
         context: @escaping () -> WorkspaceSidebarNativeContext?, @ViewBuilder content: () -> Content) {
        self.state = state
        self.model = model; self.captureFocus = captureFocus
        self.canConfigureNew = canConfigureNew
        self.spatiallyAvailable = spatiallyAvailable
        self.windowInsets = windowInsets
        self.windowCornerRadius = windowCornerRadius
        self.keepsFullConversationViewport = keepsFullConversationViewport
        self.context = context
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            let rail = SidebarRailLayout(windowInsets: windowInsets, cornerRadius: windowCornerRadius)
            let travel = min(geometry.size.width, rail.width)
            ZStack(alignment: .topLeading) {
                SidebarRailProgressLayer(state: state,
                    availableRoutes: overlays?.availableRoutes ?? [], layout: rail,
                    travel: travel, height: geometry.size.height,
                    onSelect: { route in
                        overlays?.enter(route, eligible: context()?.allowsOpening == true, captureFocus: captureFocus)
                    })
                content
                    .frame(width: geometry.size.width,
                           height: keepsFullConversationViewport ? nil : geometry.size.height)
                    // Only the single page spans behind the moving keyboard.
                    // Split, the Rail, and overlays retain the keyboard-safe viewport.
                    .ignoresSafeArea(.all, edges: keepsFullConversationViewport ? .bottom : [])
                    .accessibilityHidden(state.overlay != nil)
                    .accessibilityElement(children: .contain)
                    .accessibilityActions {
                        if spatiallyAvailable, !state.isOpen, !state.isDragging,
                           state.settlementID == nil, state.overlay == nil {
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
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: state.overlay)
            .background(Color(uiColor: .systemBackground))
            .background(WorkspaceSidebarGestureBridge(state: state, travel: travel,
                isRightToLeft: direction == .rightToLeft, context: context))
        }
        .ignoresSafeArea(.container)
        // Request the admitted Rail edge explicitly from UIKit. Keep the
        // preference through the contact/settlement, then release it for the
        // open Rail, unavailable Surface and overlay boundaries.
        .defersSystemGestures(on: defersLeadingSystemGestures
            ? (direction == .rightToLeft ? .trailing : .leading) : [])
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

    private var defersLeadingSystemGestures: Bool {
        guard spatiallyAvailable, state.overlay == nil else { return false }
        return (!state.isOpen && context()?.allowsOpening == true)
            || state.isDragging || state.settlementID != nil
    }
}

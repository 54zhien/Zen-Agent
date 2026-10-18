import SwiftUI

@MainActor
private struct SidebarRailProgressLayer: View {
    let state: WorkspaceNavigationState
    let availableRoutes: Set<WorkspaceOverlayRoute>
    let layout: SidebarRailLayout
    let travel: CGFloat
    let height: CGFloat
    let pageSize: CGSize
    let roundsPageBottom: Bool
    let pageCornerRadius: CGFloat
    let windowCornerRadius: CGFloat
    let onSelect: (WorkspaceOverlayRoute) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var direction

    var body: some View {
        let progress = CGFloat(state.progress)
        let isDragging = state.isDragging
        let settlementID = state.settlementID
        let isInteractive = state.isOpen && !isDragging && settlementID == nil

        if progress > 0 || settlementID != nil {
            let settings = layout.settingsPlacement(windowCornerRadius: windowCornerRadius,
                                                    isRightToLeft: direction == .rightToLeft)
            SidebarRailView(
                availableRoutes: availableRoutes,
                conversationActions: state.conversationActions,
                isInteractive: isInteractive,
                settingsLeadingShift: settings.leadingShift,
                onAction: state.perform,
                onSelect: onSelect
            )
            .padding(.leading, layout.leading)
            .padding(.trailing, layout.leading)
            .padding(.top, layout.top)
            .padding(.bottom, settings.bottom)
            .frame(width: travel, height: height)
            // A straight reveal edge cuts controls off inside the page's exposed
            // corner area. Subtract the rounded page silhouette instead.
            .mask(alignment: .leading) {
                SidebarRailRevealShape(pageSize: pageSize, radius: pageCornerRadius,
                    roundsBottom: roundsPageBottom, offset: travel * progress,
                    isRightToLeft: direction == .rightToLeft)
                    .fill(style: FillStyle(eoFill: true))
                    .clipped()
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
    let sidebarPageHeight: CGFloat?
    let roundsSidebarPageBottom: Bool
    let content: Content
    let model: AppShellModel?
    let captureFocus: () -> ComposerOverlayFocus?
    private struct SettingsPresentation: Identifiable {
        let id: UUID
        let model: SettingsWorkspaceModel
    }
    @State private var overlays: WorkspaceOverlayCoordinator?
    @State private var presentedSettingsID: UUID?
    @Environment(\.layoutDirection) private var direction
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(state: WorkspaceNavigationState, model: AppShellModel? = nil,
         captureFocus: @escaping () -> ComposerOverlayFocus? = { nil },
         spatiallyAvailable: Bool,
         windowInsets: EdgeInsets = EdgeInsets(), windowCornerRadius: CGFloat = 0,
         keepsFullConversationViewport: Bool = false,
         sidebarPageHeight: CGFloat? = nil, roundsSidebarPageBottom: Bool = true,
         context: @escaping () -> WorkspaceSidebarNativeContext?, @ViewBuilder content: () -> Content) {
        self.state = state
        self.model = model; self.captureFocus = captureFocus
        self.spatiallyAvailable = spatiallyAvailable
        self.windowInsets = windowInsets
        self.windowCornerRadius = windowCornerRadius
        self.keepsFullConversationViewport = keepsFullConversationViewport
        self.sidebarPageHeight = sidebarPageHeight
        self.roundsSidebarPageBottom = roundsSidebarPageBottom
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
                    pageSize: CGSize(width: geometry.size.width, height: sidebarPageHeight ?? geometry.size.height),
                    roundsPageBottom: roundsSidebarPageBottom,
                    pageCornerRadius: max(windowCornerRadius,
                        model?.splitWorkspace != nil ? SplitTargetingGeometry.paneCornerRadius : 0),
                    windowCornerRadius: windowCornerRadius,
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
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: state.overlay)
            .background(Color(uiColor: .systemBackground))
            .background(WorkspaceSidebarGestureBridge(state: state, travel: travel,
                isRightToLeft: direction == .rightToLeft, context: context))
        }
        .sheet(item: settingsPresentation, onDismiss: {
            if let id = presentedSettingsID {
                overlays?.settingsDidDismiss(expectedID: id)
                presentedSettingsID = nil
            }
        }) { item in
            SettingsWorkspaceView(model: item.model,
                onClose: { overlays?.close(expectedID: item.id) },
                onFiles: { overlays?.openFilesFromSettings(expectedID: item.id) })
                .presentationDetents([.large])
                .onAppear { presentedSettingsID = item.id }
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
                overlays?.enterNewSettings(id: id, eligible: model?.currentSettingsNewID == id,
                    captureFocus: captureFocus)
            }
        }
        .onDisappear { overlays?.reset(); state.onReset = nil; state.onConfigureNew = nil }
    }

    private var settingsPresentation: Binding<SettingsPresentation?> {
        let presentationID = state.overlayID
        return Binding(get: {
            guard state.overlay == .settings, let id = presentationID, state.overlayID == id,
                  let settings = overlays?.settings else { return nil }
            return SettingsPresentation(id: id, model: settings)
        }, set: { item in
            guard item == nil, let id = presentationID else { return }
            overlays?.close(expectedID: id)
        })
    }

    private var defersLeadingSystemGestures: Bool {
        guard spatiallyAvailable, state.overlay == nil else { return false }
        return (!state.isOpen && context()?.allowsOpening == true)
            || state.isDragging || state.settlementID != nil
    }
}

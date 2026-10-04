import SwiftUI

/// Composition only: the retained native Surface owns its own translation.
@MainActor
struct WorkspaceNavigationView<Content: View>: View {
    let state: WorkspaceNavigationState
    let context: () -> WorkspaceSidebarNativeContext?
    let spatiallyAvailable: Bool
    let content: Content
    @Environment(\.layoutDirection) private var direction

    init(state: WorkspaceNavigationState, spatiallyAvailable: Bool,
         context: @escaping () -> WorkspaceSidebarNativeContext?, @ViewBuilder content: () -> Content) {
        self.state = state
        self.spatiallyAvailable = spatiallyAvailable
        self.context = context
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            let travel = min(geometry.size.width, 60 + geometry.safeAreaInsets.leading)
            ZStack(alignment: .leading) {
                if state.progress > 0 {
                    SidebarRailView(availableRoutes: [], onSelect: { _ in })
                        .padding(.leading, geometry.safeAreaInsets.leading)
                        .padding(.top, geometry.safeAreaInsets.top)
                        .padding(.bottom, geometry.safeAreaInsets.bottom)
                        .frame(width: travel, height: geometry.size.height)
                        .background(Color(white: 0.035))
                }
                content
                    .frame(width: geometry.size.width, height: geometry.size.height)
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
            }
            .background(Color(white: 0.035))
            .background(WorkspaceSidebarGestureBridge(state: state, travel: travel,
                isRightToLeft: direction == .rightToLeft, context: context))
        }
        .ignoresSafeArea(.container)
    }
}

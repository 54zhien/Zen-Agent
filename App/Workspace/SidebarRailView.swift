import SwiftUI

@MainActor
struct SidebarRailView: View {
    let availableRoutes: Set<WorkspaceOverlayRoute>
    let onSelect: (WorkspaceOverlayRoute) -> Void

    var body: some View {
        VStack(spacing: 12) {
            destination(.search, symbol: "magnifyingglass", label: "搜索", identifier: "sidebar-search")
            destination(.files, symbol: "folder", label: "文件", identifier: "sidebar-files")
            Spacer(minLength: 20)
            destination(.settings, symbol: "gearshape", label: "设置", identifier: "sidebar-settings")
        }
        .padding(.vertical, 16)
        .frame(width: 60)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar-rail")
    }

    private func destination(_ route: WorkspaceOverlayRoute, symbol: String,
                             label: String, identifier: String) -> some View {
        Button { onSelect(route) } label: {
            Image(systemName: symbol)
                .font(.system(size: 21, weight: .regular))
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.85))
        .disabled(!availableRoutes.contains(route))
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

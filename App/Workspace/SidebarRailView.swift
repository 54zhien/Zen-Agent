import SwiftUI

struct SidebarRailLayout {
    static let contentWidth: CGFloat = 60
    let leading: CGFloat
    let top: CGFloat
    let bottom: CGFloat
    var width: CGFloat { Self.contentWidth + leading }

    init(windowInsets: EdgeInsets, cornerRadius: CGFloat) {
        if cornerRadius > Self.contentWidth / 2 {
            // Keep the existing 48-point controls and the six-point inner gap.
            leading = cornerRadius - Self.contentWidth / 2
            top = cornerRadius - 24
            bottom = cornerRadius - 24
        } else {
            leading = windowInsets.leading
            top = windowInsets.top + 16
            bottom = windowInsets.bottom + 16
        }
    }
}

@MainActor
struct SidebarRailView: View {
    let availableRoutes: Set<WorkspaceOverlayRoute>
    var conversationActions: Set<WorkspaceConversationAction> = []
    var onAction: (WorkspaceConversationAction) -> Void = { _ in }
    let onSelect: (WorkspaceOverlayRoute) -> Void

    var body: some View {
        VStack(spacing: 12) {
            ScrollView(.vertical) {
                VStack(spacing: 8) {
                action(.new, symbol: "square.and.pencil", label: "新会话", identifier: "new-conversation-new")
                action(.recent, symbol: "clock.arrow.circlepath", label: "最近会话", identifier: "new-conversation-recent")
                if conversationActions.contains(.splitTop) {
                    Menu {
                        Button("上方分屏") { onAction(.splitTop) }.accessibilityIdentifier("split-open-top")
                        Button("下方分屏") { onAction(.splitBottom) }.accessibilityIdentifier("split-open-bottom")
                    } label: {
                        Image(systemName: "rectangle.split.2x1").font(.system(size: 21))
                            .frame(width: 48, height: 48)
                            .glassEffect(.regular.interactive(), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .accessibilityLabel("分屏").accessibilityIdentifier("split-entry")
                }
                if conversationActions.contains(.configure) {
                    action(.configure, symbol: "slider.horizontal.3", label: "配置模型", identifier: "new-conversation-configure")
                }
                destination(.search, symbol: "magnifyingglass", label: "搜索", identifier: "sidebar-search")
                destination(.files, symbol: "folder", label: "文件", identifier: "sidebar-files")
                }
            }
            .scrollIndicators(.hidden)
            .scrollEdgeEffectStyle(.soft, for: .all)
            destination(.settings, symbol: "gearshape", label: "设置", identifier: "sidebar-settings")
        }
        .frame(width: SidebarRailLayout.contentWidth)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar-rail")
    }

    private func action(_ action: WorkspaceConversationAction, symbol: String, label: String, identifier: String) -> some View {
        Button { onAction(action) } label: {
            Image(systemName: symbol).font(.system(size: 21)).frame(width: 48, height: 48)
                .contentShape(Rectangle())
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .buttonStyle(.plain).foregroundStyle(.primary)
        .disabled(!conversationActions.contains(action))
        .accessibilityLabel(label).accessibilityIdentifier(identifier)
    }

    private func destination(_ route: WorkspaceOverlayRoute, symbol: String,
                             label: String, identifier: String) -> some View {
        Button { onSelect(route) } label: {
            Image(systemName: symbol)
                .font(.system(size: 21, weight: .regular))
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .disabled(!availableRoutes.contains(route))
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

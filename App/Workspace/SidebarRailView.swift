import SwiftUI

struct SidebarRailLayout {
    static let contentWidth: CGFloat = 64
    static let controlSize: CGFloat = 56
    static let iconSize: CGFloat = 25
    static let minimumLeadingInset: CGFloat = 16
    static let topSafeAreaPadding: CGFloat = 12
    static let bottomSafeAreaPadding: CGFloat = 16

    let leading: CGFloat
    let top: CGFloat
    let bottom: CGFloat
    var width: CGFloat { Self.contentWidth + leading * 2 }

    init(windowInsets: EdgeInsets, cornerRadius: CGFloat) {
        // A 16pt inset leaves a 20pt visible gap around each 56pt control in the
        // 64pt rail. Mirror it on both sides so the exposed-page gap stays equal;
        // a larger side safe area expands both gaps symmetrically.
        leading = max(windowInsets.leading, Self.minimumLeadingInset)
        top = max(cornerRadius - Self.controlSize / 2,
                  windowInsets.top + Self.topSafeAreaPadding)
        bottom = windowInsets.bottom + Self.bottomSafeAreaPadding
    }
}

enum SidebarProgressPresentation {
    static func opacity(forProgress progress: Double) -> Double {
        let clamped = progress.isFinite ? min(1, max(0, progress)) : 0
        return 0.25 + 0.75 * clamped
    }
}

@MainActor
struct SidebarRailView: View {
    let availableRoutes: Set<WorkspaceOverlayRoute>
    var conversationActions: Set<WorkspaceConversationAction> = []
    var onAction: (WorkspaceConversationAction) -> Void = { _ in }
    let onSelect: (WorkspaceOverlayRoute) -> Void

    var body: some View {
        VStack(spacing: 8) {
            ScrollView(.vertical) {
                VStack(spacing: 8) {
                    action(.new, symbol: "square.and.pencil", label: "新会话", identifier: "new-conversation-new")
                    action(.recent, symbol: "clock.arrow.circlepath", label: "最近会话", identifier: "new-conversation-recent")
                    if conversationActions.contains(.splitTop) {
                        Menu {
                            Button("上方分屏") { onAction(.splitTop) }.accessibilityIdentifier("split-open-top")
                            Button("下方分屏") { onAction(.splitBottom) }.accessibilityIdentifier("split-open-bottom")
                        } label: {
                            Image(systemName: "rectangle.split.2x1")
                                .font(.system(size: SidebarRailLayout.iconSize))
                                .frame(width: SidebarRailLayout.controlSize, height: SidebarRailLayout.controlSize)
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
            .scrollClipDisabled()
            // Keep the glass halo outside the narrow column without allowing
            // scrolled controls to paint over the status area or Settings.
            .mask { Rectangle().padding(.horizontal, -16).padding(.vertical, -8) }
            .scrollEdgeEffectHidden(true, for: .all)
            destination(.settings, symbol: "gearshape", label: "设置", identifier: "sidebar-settings")
        }
        .frame(width: SidebarRailLayout.contentWidth)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar-rail")
    }

    private func action(_ action: WorkspaceConversationAction, symbol: String, label: String, identifier: String) -> some View {
        Button { onAction(action) } label: {
            Image(systemName: symbol).font(.system(size: SidebarRailLayout.iconSize))
                .frame(width: SidebarRailLayout.controlSize, height: SidebarRailLayout.controlSize)
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
                .font(.system(size: SidebarRailLayout.iconSize, weight: .regular))
                .frame(width: SidebarRailLayout.controlSize, height: SidebarRailLayout.controlSize)
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

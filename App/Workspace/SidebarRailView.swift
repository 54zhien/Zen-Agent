import SwiftUI
import UIKit

/// The Rail is composited above the full-viewport native host. Reveal only
/// the area outside the moving page, including its rounded display corners.
/// Subtract the page's filled region, then clip to the Rail's bounds.
struct SidebarRailRevealShape: Shape {
    var pageSize: CGSize
    var radius: CGFloat
    var roundsBottom: Bool
    var offset: CGFloat
    var isRightToLeft: Bool

    var animatableData: CGFloat {
        get { offset }
        set { offset = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let pageX = isRightToLeft ? rect.maxX - pageSize.width - offset : rect.minX + offset
        let page = CGRect(x: pageX, y: rect.minY, width: pageSize.width, height: pageSize.height)
        let bottom = roundsBottom ? radius : 0
        let shape = UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: bottom,
            bottomTrailingRadius: bottom, topTrailingRadius: radius, style: .continuous)
        return Path(rect).subtracting(shape.path(in: page), eoFill: true)
    }
}

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

    /// Settings shares the display corner's center, so its glass circle reads
    /// as concentric with the screen. Too small a corner keeps the column slot.
    func settingsPlacement(windowCornerRadius radius: CGFloat,
                           isRightToLeft: Bool = false) -> (bottom: CGFloat, leadingShift: CGFloat) {
        let half = Self.controlSize / 2
        guard radius.isFinite, radius >= half + 8 else { return (bottom, 0) }
        let columnLeading = leading + (Self.contentWidth - Self.controlSize) / 2
        let shift = (radius - half) - columnLeading
        return (radius - half, isRightToLeft ? -shift : shift)
    }
}

enum SidebarProgressPresentation {
    /// Opacity of the hairline gray that the Split divider fades into and that
    /// outlines the page while the Sidebar is open, over `label` in both appearances.
    static let edgeOpacity: CGFloat = 0.16

    static func edgeColor(traits: UITraitCollection) -> UIColor {
        UIColor.label.resolvedColor(with: traits).withAlphaComponent(edgeOpacity)
    }

    static func opacity(forProgress progress: Double) -> Double {
        let clamped = progress.isFinite ? min(1, max(0, progress)) : 0
        return 0.25 + 0.75 * clamped
    }
}

@MainActor
struct SidebarRailView: View {
    let availableRoutes: Set<WorkspaceOverlayRoute>
    var conversationActions: Set<WorkspaceConversationAction> = []
    /// While the Rail is still moving its controls are inert but keep their
    /// resting appearance; dimming them read as a half-loaded Sidebar.
    var isInteractive = true
    var settingsLeadingShift: CGFloat = 0
    var onAction: (WorkspaceConversationAction) -> Void = { _ in }
    let onSelect: (WorkspaceOverlayRoute) -> Void

    var body: some View {
        VStack(spacing: 8) {
            // The column stays put. Only a window too short to hold every
            // control falls back to scrolling instead of clipping one away.
            ViewThatFits(in: .vertical) {
                VStack(spacing: 8) { controls }
                ScrollView(.vertical) {
                    VStack(spacing: 8) { controls }
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
                .mask { Rectangle().padding(.horizontal, -16).padding(.vertical, -8) }
                .scrollEdgeEffectHidden(true, for: .all)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            destination(.settings, symbol: "gearshape", label: "设置", identifier: "sidebar-settings")
                .offset(x: settingsLeadingShift)
        }
        .frame(width: SidebarRailLayout.contentWidth)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar-rail")
    }

    @ViewBuilder private var controls: some View {
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
            .buttonStyle(SidebarRailButtonStyle(unavailable: false))
            .disabled(!isInteractive)
            .foregroundStyle(.primary)
            .accessibilityLabel("分屏").accessibilityIdentifier("split-entry")
        }
        destination(.search, symbol: "magnifyingglass", label: "搜索", identifier: "sidebar-search")
        destination(.files, symbol: "folder", label: "文件", identifier: "sidebar-files")
    }

    private func action(_ action: WorkspaceConversationAction, symbol: String, label: String, identifier: String) -> some View {
        Button { onAction(action) } label: {
            Image(systemName: symbol).font(.system(size: SidebarRailLayout.iconSize))
                .frame(width: SidebarRailLayout.controlSize, height: SidebarRailLayout.controlSize)
                .contentShape(Rectangle())
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .buttonStyle(SidebarRailButtonStyle(unavailable: !conversationActions.contains(action)))
        .foregroundStyle(.primary)
        .disabled(!isInteractive || !conversationActions.contains(action))
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
        .buttonStyle(SidebarRailButtonStyle(unavailable: !availableRoutes.contains(route)))
        .foregroundStyle(.primary)
        .disabled(!isInteractive || !availableRoutes.contains(route))
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

/// Dims only a genuinely unavailable control. Inertness during Rail motion is
/// expressed through `disabled` alone, so the glass stays solid while sliding.
private struct SidebarRailButtonStyle: ButtonStyle {
    let unavailable: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(unavailable ? 0.35 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
            .animation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.3), value: configuration.isPressed)
    }
}

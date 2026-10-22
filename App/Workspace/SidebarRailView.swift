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
    @State private var tapFeedback = UIImpactFeedbackGenerator(style: .medium)

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
        .onAppear { tapFeedback.prepare() }
    }

    @ViewBuilder private var controls: some View {
        VStack(spacing: 0) {
            action(.new, symbol: "message", label: "新会话", identifier: "new-conversation-new")
            destination(.search, symbol: "magnifyingglass", label: "搜索", identifier: "sidebar-search", grouped: true)
            action(.recent, symbol: "clock.arrow.circlepath", label: "最近会话", identifier: "new-conversation-recent")
        }
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar-conversation-controls")
        destination(.files, symbol: "folder", label: "文件", identifier: "sidebar-files")
    }

    private func action(_ action: WorkspaceConversationAction, symbol: String, label: String, identifier: String) -> some View {
        Button {
            tapFeedback.impactOccurred()
            onAction(action)
        } label: {
            controlIcon(symbol)
        }
        .buttonStyle(SidebarRailButtonStyle(unavailable: !conversationActions.contains(action)))
        .foregroundStyle(.primary)
        .disabled(!isInteractive || !conversationActions.contains(action))
        .accessibilityLabel(label).accessibilityIdentifier(identifier)
    }

    private func destination(_ route: WorkspaceOverlayRoute, symbol: String,
                             label: String, identifier: String, grouped: Bool = false) -> some View {
        Button {
            tapFeedback.impactOccurred()
            onSelect(route)
        } label: {
            if grouped {
                controlIcon(symbol)
            } else {
                controlIcon(symbol)
                    .glassEffect(.regular.interactive(), in: Circle())
            }
        }
        .buttonStyle(SidebarRailButtonStyle(unavailable: !availableRoutes.contains(route)))
        .foregroundStyle(.primary)
        .disabled(!isInteractive || !availableRoutes.contains(route))
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private func controlIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: SidebarRailLayout.iconSize, weight: .regular))
            .frame(width: SidebarRailLayout.controlSize, height: SidebarRailLayout.controlSize)
            .contentShape(Rectangle())
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

#if DEBUG
/// A temporary component boundary, using the measured iPhone fixture geometry.
/// The receipt proves action delivery only, not the production Settings route.
@MainActor
struct SidebarAXIsolationFixture: View {
    @State private var receivedSettings = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                SidebarRailView(availableRoutes: [.search, .files, .settings],
                    conversationActions: [.new, .recent], settingsLeadingShift: 14,
                    onSelect: { if $0 == .settings { receivedSettings = true } })
                    .padding(.horizontal, 16)
                    .padding(.top, 74)
                    .padding(.bottom, 34)
                    .frame(width: 96, height: geometry.size.height)
                if receivedSettings {
                    Text("Settings action received")
                        .accessibilityIdentifier("sidebar-isolated-settings-receipt")
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .background(Color(uiColor: .systemBackground))
        }
        .ignoresSafeArea()
    }
}
#endif

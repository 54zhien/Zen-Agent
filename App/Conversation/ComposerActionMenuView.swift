import Observation
import SwiftUI
import UIKit

@MainActor @Observable
final class ComposerActionMenuState {
    var activeLevel: ComposerActionMenuLevel = .actions
    var models: [ModelDescriptor] = []
    var selectedModelID: ModelID?
    var supportedThinkingEfforts: [ThinkingEffort] = []
    var selectedThinkingEffort: ThinkingEffort?
    var defaultThinkingEffort: ThinkingEffort?
    @ObservationIgnored var onSelectThinking: (ThinkingEffort?) -> Void = { _ in }

    var thinkingLevel: ThinkingEffort? {
        if let selectedThinkingEffort { return selectedThinkingEffort }
        return defaultLevel
    }

    var defaultLevel: ThinkingEffort? {
        guard let defaultThinkingEffort, supportedThinkingEfforts.contains(defaultThinkingEffort) else { return nil }
        return defaultThinkingEffort
    }
}

enum ComposerActionMenuLevel: Equatable {
    case actions
    case models
    case thinking
}

struct ComposerActionMenuView: View {
    let level: ComposerActionMenuLevel
    let presentation: ComposerActionMenuState
    let maximumSize: CGSize
    let onSelect: (ModelID) -> Void
    let onOpenModels: (CGRect) -> Void
    let onReturn: () -> Void
    var keyboardSheet = false
    var onOpenThinking: (CGRect) -> Void = { _ in }
    @State private var modelRow = CGRect.zero
    @State private var thinkingRow = CGRect.zero
    @ScaledMetric(relativeTo: .body) private var leading: CGFloat = 32
    @ScaledMetric(relativeTo: .body) private var iconDiameter: CGFloat = 38

    var body: some View {
        // Each native panel keeps a fixed level; a child never replaces its parent.
        Group {
            switch level {
            case .actions: actions
            case .models: modelMenu
            case .thinking: thinkingMenu
            }
        }
        .font(.body)
        .foregroundStyle(.primary)
        .buttonStyle(.plain)
        .frame(width: maximumSize.width)
        .frame(maxHeight: maximumSize.height)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(panelIdentifier)
        .accessibilityHidden(level != presentation.activeLevel)
        .coordinateSpace(name: "composer-menu-panel")
    }

    private var panelIdentifier: String {
        switch level {
        case .actions: "composer-action-menu"
        case .models: "composer-model-picker"
        case .thinking: "composer-thinking-picker"
        }
    }

    nonisolated private static func rowFrame(_ proxy: GeometryProxy) -> CGRect {
        proxy.frame(in: .named("composer-menu-panel"))
    }

    private var actions: some View {
        ViewThatFits(in: .vertical) {
            actionRows
            ScrollView { actionRows }.scrollBounceBehavior(.basedOnSize)
        }
        .frame(width: maximumSize.width)
    }

    private var actionRows: some View {
        VStack(spacing: 0) {
            if keyboardSheet {
                modelAction
                thinkingAction
                unavailable("插件", symbol: "powercord")
                unavailable("图片", symbol: "photo.on.rectangle.angled")
                unavailable("文件", symbol: "paperclip")
            } else {
                thinkingAction
                modelAction
                unavailable("插件", symbol: "powercord")
                unavailable("添加文件", symbol: "paperclip")
                unavailable("添加图片", symbol: "photo.on.rectangle.angled")
            }
        }
        .padding(.vertical, keyboardSheet ? 0 : 12)
        .frame(width: maximumSize.width)
    }

    private var thinkingAction: some View {
        actionControl("思考", symbol: "tachometer", opensMenu: true,
                      value: presentation.thinkingLevel?.title ?? "模型默认") {
            onOpenThinking(thinkingRow)
        }
        .onGeometryChange(for: CGRect.self, of: Self.rowFrame) { thinkingRow = $0 }
    }

    private var modelAction: some View {
        actionControl("模型", symbol: "theatermasks", opensMenu: true) {
            onOpenModels(modelRow)
        }
        .disabled(presentation.models.isEmpty)
        .onGeometryChange(for: CGRect.self, of: Self.rowFrame) { modelRow = $0 }
    }

    private func unavailable(_ title: String, symbol: String) -> some View {
        actionControl(title, symbol: symbol) {}
            .foregroundStyle(.tertiary)
            .disabled(true)
    }

    @ViewBuilder
    private func actionControl(_ title: String, symbol: String, opensMenu: Bool = false,
                               value: String = "", action: @escaping () -> Void) -> some View {
        if presentation.activeLevel == .actions {
            Button(action: action) { actionLabel(title, symbol: symbol, opensMenu: opensMenu) }
                .accessibilityLabel(title)
                .accessibilityValue(value)
        } else {
            // UIKit and a container-level AX flag can retain SwiftUI buttons.
            // Keep the same visual background without inactive controls behind a child.
            actionLabel(title, symbol: symbol, opensMenu: opensMenu).accessibilityHidden(true)
        }
    }

    private func actionLabel(_ title: String, symbol: String, opensMenu: Bool = false) -> some View {
        HStack(spacing: 12) {
            if keyboardSheet {
                menuSymbol(symbol)
                    .frame(width: 21, height: 21)
                    .frame(width: iconDiameter, height: iconDiameter)
                    .background(Color(uiColor: .secondarySystemFill), in: Circle())
                    .accessibilityHidden(true)
            } else {
                menuSymbol(symbol).frame(width: 22, height: 22).accessibilityHidden(true)
            }
            Text(title)
            Spacer()
            if opensMenu {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, keyboardSheet ? 20 : leading)
        .padding(.trailing, 24)
        .padding(.vertical, keyboardSheet ? 8 : 12)
        .frame(minHeight: keyboardSheet ? max(54, min(72, maximumSize.height / 5)) : 44)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func menuSymbol(_ name: String) -> some View {
        if name == "tachometer", let level = presentation.thinkingLevel {
            ComposerThinkingIcon(level: level)
        } else {
            Image(systemName: name)
                .resizable()
                .scaledToFit()
                .fontWeight(.medium)
                .rotationEffect(.degrees(name == "powercord" ? -45 : 0))
        }
    }

    private var thinkingMenu: some View {
        VStack(spacing: 0) {
            Button(action: onReturn) {
                HStack(spacing: 12) {
                    menuSymbol("tachometer").frame(width: 22, height: 22)
                    Text("思考").fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "chevron.down").fontWeight(.semibold)
                }
                .padding(.leading, leading).padding(.trailing, 24).padding(.vertical, 16)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("思考")
            Divider().padding(.horizontal, 24)
            if presentation.supportedThinkingEfforts.isEmpty {
                Text("当前模型不支持调整思考档位")
                    .font(.callout).foregroundStyle(.secondary).padding(24)
            } else {
                ViewThatFits(in: .vertical) {
                    thinkingOptions
                    ScrollView { thinkingOptions }.scrollBounceBehavior(.basedOnSize)
                }
            }
        }
        .padding(.bottom, 12)
        .frame(width: maximumSize.width)
        .frame(maxHeight: maximumSize.height)
    }

    private var thinkingOptions: some View {
        VStack(spacing: 0) {
            thinkingChoice(nil)
            ForEach(presentation.supportedThinkingEfforts, id: \.self) { thinkingChoice($0) }
        }
    }

    private func thinkingChoice(_ effort: ThinkingEffort?) -> some View {
        Button { presentation.onSelectThinking(effort) } label: {
            HStack(spacing: 12) {
                if let icon = effort ?? presentation.defaultLevel {
                    ComposerThinkingIcon(level: icon).frame(width: 22, height: 22)
                }
                Text(effort?.title ?? "模型默认")
                Spacer()
                Image(systemName: "checkmark").font(.subheadline.weight(.semibold))
                    .opacity(presentation.selectedThinkingEffort == effort ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.leading, leading).padding(.trailing, 24).padding(.vertical, 12)
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .accessibilityLabel(effort?.title ?? "模型默认")
        .accessibilityIdentifier("thinking-level-\(effort?.rawValue ?? "default")")
        .accessibilityAddTraits(presentation.selectedThinkingEffort == effort ? .isSelected : [])
    }

    private var modelMenu: some View {
        VStack(spacing: 0) {
            Button(action: onReturn) {
                HStack(spacing: 12) {
                    Image(systemName: "theatermasks")
                    Text("模型").fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "chevron.down").fontWeight(.semibold)
                }
                .padding(.leading, leading)
                .padding(.trailing, 24)
                .padding(.vertical, 16)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("模型")
            Divider().padding(.horizontal, 24)
            ViewThatFits(in: .vertical) {
                options
                ScrollView { options }
                    .scrollBounceBehavior(.basedOnSize)
            }
        }
        .padding(.bottom, 12)
        .frame(width: maximumSize.width)
        .frame(maxHeight: maximumSize.height)
        .accessibilityElement(children: .contain)
    }

    private var options: some View {
        VStack(spacing: 0) {
            ForEach(presentation.models, id: \.id) { model in
                Button { onSelect(model.id) } label: {
                    HStack(spacing: 12) {
                        Text(model.displayName)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "checkmark")
                            .font(.subheadline.weight(.semibold))
                            .opacity(model.id == presentation.selectedModelID ? 1 : 0)
                            .accessibilityHidden(true)
                    }
                    .padding(.leading, leading)
                    .padding(.trailing, 24)
                    .padding(.vertical, 12)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityAddTraits(model.id == presentation.selectedModelID ? .isSelected : [])
            }
        }
    }
}

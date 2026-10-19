import Observation
import SwiftUI
import UIKit

@MainActor @Observable
final class ComposerActionMenuState {
    var models: [ModelDescriptor] = []
    var selectedModelID: ModelID?
}

struct ComposerActionMenuView: View {
    let presentation: ComposerActionMenuState
    let maximumSize: CGSize
    let onSelect: (ModelID) -> Void
    let onSizeChanged: (CGSize) -> Void
    @State private var showsModels = false
    @Namespace private var glassNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var leading: CGFloat = 32
    @ScaledMetric(relativeTo: .body) private var checkLeading: CGFloat = 8

    var body: some View {
        GlassEffectContainer {
            ZStack(alignment: .bottomLeading) {
                if showsModels {
                    modelMenu
                        .glassEffect(.regular, in: .rect(cornerRadius: 28))
                        .glassEffectID("composer-menu", in: glassNamespace)
                        .glassEffectTransition(.matchedGeometry)
                } else {
                    actions
                        .glassEffect(.regular, in: .rect(cornerRadius: 28))
                        .glassEffectID("composer-menu", in: glassNamespace)
                        .glassEffectTransition(.matchedGeometry)
                }
            }
        }
        .font(.body)
        .foregroundStyle(.primary)
        .buttonStyle(.plain)
        .frame(width: maximumSize.width)
        .frame(maxHeight: maximumSize.height)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer-action-menu")
        .onGeometryChange(for: CGSize.self, of: Self.panelSize) { onSizeChanged($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    // SwiftUI may measure during async rendering. This projection must not
    // inherit the View's MainActor isolation; only the size-change action owns UI state.
    nonisolated private static func panelSize(_ proxy: GeometryProxy) -> CGSize { proxy.size }

    private var actions: some View {
        ViewThatFits(in: .vertical) {
            actionRows
            ScrollView { actionRows }.scrollBounceBehavior(.basedOnSize)
        }
        .frame(width: maximumSize.width)
    }

    private var actionRows: some View {
        VStack(spacing: 0) {
            unavailable("推理强度", symbol: "slider.horizontal.3")
            Button { navigate(toModels: true) } label: {
                actionLabel("模型", symbol: "cpu", opensMenu: true)
            }
            .disabled(presentation.models.isEmpty)
            .accessibilityLabel("模型")
            unavailable("插件", symbol: "puzzlepiece")
            unavailable("添加文件", symbol: "doc")
            unavailable("添加图片", symbol: "photo")
        }
        .padding(.vertical, 12)
        .frame(width: maximumSize.width)
    }

    private func unavailable(_ title: String, symbol: String) -> some View {
        Button {} label: { actionLabel(title, symbol: symbol).foregroundStyle(.tertiary) }
            .disabled(true)
            .accessibilityLabel(title)
    }

    private func actionLabel(_ title: String, symbol: String, opensMenu: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 22).accessibilityHidden(true)
            Text(title)
            Spacer()
            if opensMenu {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, leading)
        .padding(.trailing, 24)
        .padding(.vertical, 12)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private var modelMenu: some View {
        VStack(spacing: 0) {
            Button { navigate(toModels: false) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "cpu")
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
        .accessibilityIdentifier("composer-model-picker")
    }

    private func navigate(toModels: Bool) {
        WorkspaceHaptics.shared.play(.control)
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.26)) { showsModels = toModels }
    }

    private var options: some View {
        VStack(spacing: 0) {
            ForEach(presentation.models, id: \.id) { model in
                Button { onSelect(model.id) } label: {
                    Text(model.displayName)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, leading)
                        .padding(.trailing, 24)
                        .padding(.vertical, 12)
                        .frame(minHeight: 44)
                        .overlay(alignment: .leading) {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .padding(.leading, checkLeading)
                                .opacity(model.id == presentation.selectedModelID ? 1 : 0)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                }
                .accessibilityAddTraits(model.id == presentation.selectedModelID ? .isSelected : [])
            }
        }
    }
}

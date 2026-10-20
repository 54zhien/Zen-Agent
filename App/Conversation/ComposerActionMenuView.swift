import Observation
import SwiftUI
import UIKit

@MainActor @Observable
final class ComposerActionMenuState {
    var models: [ModelDescriptor] = []
    var selectedModelID: ModelID?
}

enum ComposerActionMenuLevel: Equatable {
    case actions
    case models
}

struct ComposerActionMenuView: View {
    let level: ComposerActionMenuLevel
    let presentation: ComposerActionMenuState
    let maximumSize: CGSize
    let onSelect: (ModelID) -> Void
    let onOpenModels: (CGRect) -> Void
    let onReturn: () -> Void
    var keyboardSheet = false
    @State private var modelRow = CGRect.zero
    @ScaledMetric(relativeTo: .body) private var leading: CGFloat = 32
    @ScaledMetric(relativeTo: .body) private var iconDiameter: CGFloat = 38

    var body: some View {
        // Each native panel keeps a fixed level; a child never replaces its parent.
        Group {
            switch level {
            case .actions: actions
            case .models: modelMenu
            }
        }
        .font(.body)
        .foregroundStyle(.primary)
        .buttonStyle(.plain)
        .frame(width: maximumSize.width)
        .frame(maxHeight: maximumSize.height)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(level == .actions ? "composer-action-menu" : "composer-model-picker")
        .coordinateSpace(name: "composer-menu-panel")
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
                unavailable("思考", symbol: "slider.horizontal.3")
                unavailable("插件", symbol: "puzzlepiece")
                unavailable("图片", symbol: "photo")
                unavailable("文件", symbol: "doc")
            } else {
                unavailable("思考", symbol: "slider.horizontal.3")
                modelAction
                unavailable("插件", symbol: "puzzlepiece")
                unavailable("添加文件", symbol: "doc")
                unavailable("添加图片", symbol: "photo")
            }
        }
        .padding(.vertical, keyboardSheet ? 0 : 12)
        .frame(width: maximumSize.width)
    }

    private var modelAction: some View {
        Button { onOpenModels(modelRow) } label: {
            actionLabel("模型", symbol: "cpu", opensMenu: true)
        }
        .disabled(presentation.models.isEmpty)
        .accessibilityLabel("模型")
        .onGeometryChange(for: CGRect.self, of: Self.rowFrame) { modelRow = $0 }
    }

    private func unavailable(_ title: String, symbol: String) -> some View {
        Button {} label: { actionLabel(title, symbol: symbol).foregroundStyle(.tertiary) }
            .disabled(true)
            .accessibilityLabel(title)
    }

    private func actionLabel(_ title: String, symbol: String, opensMenu: Bool = false) -> some View {
        HStack(spacing: 12) {
            if keyboardSheet {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: iconDiameter, height: iconDiameter)
                    .background(Color(uiColor: .secondarySystemFill), in: Circle())
                    .accessibilityHidden(true)
            } else {
                Image(systemName: symbol).frame(width: 22).accessibilityHidden(true)
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

    private var modelMenu: some View {
        VStack(spacing: 0) {
            Button(action: onReturn) {
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

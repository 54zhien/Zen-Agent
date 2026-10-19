import SwiftUI
import UIKit

@MainActor
final class ComposerModelMenuController: UIHostingController<ComposerModelMenuView>,
                                         UIPopoverPresentationControllerDelegate {
    func adaptivePresentationStyle(for controller: UIPresentationController,
                                   traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        .none
    }
}

struct ComposerModelMenuView: View {
    let models: [ModelDescriptor]
    let selectedModelID: ModelID?
    let onSelect: (ModelID) -> Void
    let onClose: () -> Void
    @ScaledMetric(relativeTo: .body) private var leading: CGFloat = 32
    @ScaledMetric(relativeTo: .body) private var checkLeading: CGFloat = 8

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onClose) {
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
        .font(.body)
        .foregroundStyle(.primary)
        .buttonStyle(.plain)
        .padding(.bottom, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer-model-picker")
    }

    private var options: some View {
        VStack(spacing: 0) {
            ForEach(models, id: \.id) { model in
                Button { onSelect(model.id) } label: {
                    Text(model.displayName)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, leading)
                        .padding(.trailing, 24)
                        .padding(.vertical, 12)
                        .overlay(alignment: .leading) {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .padding(.leading, checkLeading)
                                .opacity(model.id == selectedModelID ? 1 : 0)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                }
                .accessibilityAddTraits(model.id == selectedModelID ? .isSelected : [])
            }
        }
    }
}

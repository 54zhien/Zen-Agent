import SwiftUI

struct ConversationComposerView: View {
    @Bindable var controller: ComposerController

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isEditorFocused = false
    @State private var measuredTextHeight: CGFloat = 0
    @State private var keyboardAnimation: Animation?

    init(controller: ComposerController) {
        self.controller = controller
    }

    var body: some View {
        GeometryReader { geometry in
            let lineHeight = ComposerTextView.scaledLineHeight(
                for: .interfaceBody,
                dynamicTypeSize: dynamicTypeSize
            )
            // The host's safe-area layout follows the keyboard; do not subtract its frame again.
            let layout = ComposerGeometry.resolve(
                state: controller.draft.presentationState,
                containerWidth: geometry.size.width,
                availableHeight: geometry.size.height,
                measuredTextHeight: measuredTextHeight,
                scaledLineHeight: lineHeight,
                collapseProgress: controller.collapseProgress
            )
            let shape = ComposerShapeToken.shape(for: layout)

            ZStack(alignment: .topLeading) {
                shape.fill(.regularMaterial)
                    .frame(width: layout.visualFrame.width, height: layout.visualFrame.height)
                    .position(x: layout.visualFrame.midX, y: layout.visualFrame.midY)

                composerContent(layout: layout)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .containerShape(shape)
            .contentShape(Rectangle())
            .animation(keyboardAnimation, value: geometry.size.height)
            .simultaneousGesture(
                SpatialTapGesture().onEnded { tap in
                    guard !layout.visualFrame.contains(tap.location) else { return }
                    apply(controller.handle(.conversationBackgroundTapped))
                }
            )
        }
    }

    @ViewBuilder
    private func composerContent(layout: ComposerLayout) -> some View {
        switch ComposerTextProjection.presentation(for: controller.draft) {
        case .editor:
            ComposerTextView(
                text: $controller.draft.text,
                selection: $controller.draft.selection,
                isFocused: $isEditorFocused,
                typographyRole: layout.typographyRole,
                dynamicTypeSize: dynamicTypeSize,
                textAreaIsScrollable: layout.textAreaIsScrollable,
                onCompositionChange: updateComposition(isComposing:),
                onKeyboardTransition: handleKeyboardTransition(_:),
                onMeasuredTextHeight: { measuredTextHeight = $0 }
            )
            .frame(width: layout.textFrame.width, height: layout.textFrame.height)
            .position(x: layout.textFrame.midX, y: layout.textFrame.midY)

        case let .preview(text, lineLimit, truncation):
            Button(action: enterEditing) {
                Text(text)
                    .font(Typography.font(
                        for: layout.typographyRole,
                        dynamicTypeSize: dynamicTypeSize
                    ))
                    .lineLimit(lineLimit)
                    .truncationMode(truncation == .tail ? .tail : .middle)
                    .scaleEffect(layout.fontScale, anchor: .leading)
                    .frame(width: layout.textFrame.width, height: layout.textFrame.height)
            }
            .buttonStyle(.plain)
            .frame(width: layout.hitFrame.width, height: layout.hitFrame.height)
            .contentShape(Rectangle())
            .position(x: layout.hitFrame.midX, y: layout.hitFrame.midY)
        }
    }

    private func enterEditing() {
        let event: ComposerPresentationEvent = controller.draft.presentationState == .compact
            ? .compactTapped
            : .textAreaTapped
        apply(controller.handle(event))
    }

    private func updateComposition(isComposing: Bool) {
        guard let transition = controller.updateComposition(isComposing: isComposing) else { return }
        apply(transition)
    }

    private func handleKeyboardTransition(_ transition: ComposerKeyboardTransition) {
        guard let animation = transition.animation else {
            if !transition.isVisible {
                apply(controller.handle(.keyboardDismissed))
            }
            return
        }

        keyboardAnimation = animation.swiftUIAnimation
        guard !transition.isVisible else { return }
        withAnimation(animation.swiftUIAnimation) {
            apply(controller.handle(.keyboardDismissed))
        }
    }

    private func apply(_ transition: ComposerTransition) {
        switch transition.focusCommand {
        case .none:
            break
        case .requestFocus:
            isEditorFocused = true
        case .requestResign:
            isEditorFocused = false
        }
    }
}

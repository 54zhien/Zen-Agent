import SwiftUI

@MainActor
struct ConversationComposerView: View {
    let conversationID: String
    @Bindable var controller: ComposerController
    private let bridge: ComposerRuntimeActionBridge
    @State private var coordinator: ComposerSendCoordinator
    @State private var runProjection: RunProjection?
    @State private var knownModels: [ModelDescriptor] = []

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isEditorFocused = false
    @State private var measuredTextHeight: CGFloat = 0
    @State private var measuredQuoteShelfHeight: CGFloat = 44
    @State private var keyboardAnimation: Animation?

    init(
        conversationID: String,
        controller: ComposerController,
        bridge: ComposerRuntimeActionBridge,
        maxProviderSteps: Int
    ) {
        self.conversationID = conversationID
        self.controller = controller
        self.bridge = bridge
        _coordinator = State(initialValue: ComposerSendCoordinator(
            conversationID: conversationID,
            controller: controller,
            configuration: controller.configuration,
            bridge: bridge,
            maxProviderSteps: maxProviderSteps
        ))
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
                collapseProgress: controller.effectiveCollapseProgress
            )
            let shape = ComposerShapeToken.shape(for: layout)
            let actionState = ComposerContextAction.resolve(
                projection: runProjection,
                presentationState: controller.draft.presentationState,
                sendable: isSendable,
                hasDraft: hasDraft,
                plusAvailable: plusAvailable,
                submission: coordinator.submission
            )

            ZStack(alignment: .topLeading) {
                Color.clear
                    .frame(width: geometry.size.width, height: geometry.size.height)

                shape.fill(.regularMaterial)
                    .frame(width: layout.visualFrame.width, height: layout.visualFrame.height)
                    .contentShape(shape)
                    .position(x: layout.visualFrame.midX, y: layout.visualFrame.midY)

                let shelfVisible = !controller.draft.references.isEmpty
                    && controller.draft.presentationState != .compact
                let shelfFrame = QuoteShelfGeometry.resolve(
                    layout: layout,
                    container: CGRect(origin: .zero, size: geometry.size),
                    measuredHeight: measuredQuoteShelfHeight,
                    isVisible: shelfVisible
                )
                let dropFrame = QuoteShelfGeometry.dropFrame(layout: layout, shelfFrame: shelfFrame)
                QuoteDropTargetView(
                    existing: controller.draft.references,
                    onAccept: { reference in _ = controller.addQuoteReference(reference) },
                    onPhaseChanged: { phase in apply(controller.handle(.quoteDragPhaseChanged(phase))) }
                )
                .frame(width: dropFrame.width, height: dropFrame.height)
                .position(x: dropFrame.midX, y: dropFrame.midY)

                composerContent(layout: layout, shape: shape)
                contextControls(layout: layout, shape: shape, state: actionState)

                if let shelfFrame {
                    QuoteShelfView(
                        entries: controller.draft.references.map(QuoteShelfEntry.init),
                        onRemove: controller.removeQuoteReference(id:),
                        onMeasuredHeight: { measuredQuoteShelfHeight = $0 }
                    )
                    .frame(width: shelfFrame.width, height: shelfFrame.height)
                    .position(x: shelfFrame.midX, y: shelfFrame.midY)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .animation(keyboardAnimation, value: geometry.size.height)
            .simultaneousGesture(
                SpatialTapGesture().onEnded { tap in
                    guard !layout.visualFrame.contains(tap.location) else { return }
                    apply(controller.handle(.conversationBackgroundTapped))
                }
            )
            .task(id: conversationID) {
                await observeRunProjection()
            }
            .task(id: controller.configuration.providerInstanceID) {
                await loadKnownModels()
            }
        }
    }

    private var attachmentPipeline: ComposerAttachmentPipelineStatus {
        ComposerAttachmentPipelineStatus(
            imagePickerReady: false,
            filePickerReady: false,
            fileAssetIngestReady: false,
            messageAttachmentCommitReady: false,
            nativeImageEncodingReady: false,
            nativeFileEncodingReady: false,
            authorizedLocalImageRouteReady: false,
            authorizedLocalFileRouteReady: false
        )
    }

    private var selectedCapabilities: Set<ModelCapability> {
        knownModels.first {
            $0.providerInstanceID == controller.configuration.providerInstanceID
                && $0.id == controller.configuration.modelID
        }?.capabilities ?? []
    }

    private var canAddImage: Bool {
        ComposerActionPolicy.canAddImage(
            capabilities: selectedCapabilities,
            pipeline: attachmentPipeline
        )
    }

    private var canAddFile: Bool {
        ComposerActionPolicy.canAddFile(
            capabilities: selectedCapabilities,
            pipeline: attachmentPipeline
        )
    }

    private var canOpenPlugins: Bool {
        ComposerActionPolicy.canOpenPlugins([])
    }

    private var isSendable: Bool {
        ComposerActionPolicy.isSendable(
            draft: controller.draft,
            capabilities: selectedCapabilities,
            quoteCommitReady: true,
            imageInputReady: false,
            fileInputReady: false
        )
    }

    private var hasDraft: Bool {
        !controller.draft.text.isEmpty
            || !controller.draft.references.isEmpty
            || !controller.draft.attachments.isEmpty
    }

    private var plusAvailable: Bool {
        canAddImage || canAddFile || canOpenPlugins || !modelsForSelectedInstance.isEmpty
    }

    private var modelsForSelectedInstance: [ModelDescriptor] {
        knownModels.filter {
            $0.providerInstanceID == controller.configuration.providerInstanceID
        }
    }

    @ViewBuilder
    private func contextControls(
        layout: ComposerLayout,
        shape: ConcentricRectangle,
        state: ComposerContextActionState
    ) -> some View {
        if state.showsPlus,
           let frame = ComposerContextAction.leadingPlusFrame(
            layout: layout,
            state: controller.draft.presentationState
           ) {
            Menu {
                Button {} label: {
                    Label("添加图片", systemImage: "photo")
                }
                .disabled(!canAddImage)

                Button {} label: {
                    Label("添加文件", systemImage: "doc")
                }
                .disabled(!canAddFile)

                Button {} label: {
                    Label("插件", systemImage: "puzzlepiece")
                }
                .disabled(!canOpenPlugins)

                if modelsForSelectedInstance.isEmpty {
                    Button {} label: {
                        Label("模型", systemImage: "cpu")
                    }
                    .disabled(true)
                } else {
                    Menu {
                        ForEach(modelsForSelectedInstance) { model in
                            Button {
                                controller.configuration.modelID = model.id
                            } label: {
                                if model.id == controller.configuration.modelID {
                                    Label(model.displayName, systemImage: "checkmark")
                                } else {
                                    Text(model.displayName)
                                }
                            }
                        }
                    } label: {
                        Label("模型", systemImage: "cpu")
                    }
                }

                Button {} label: {
                    Label("推理强度", systemImage: "slider.horizontal.3")
                }
                .disabled(true)
            } label: {
                Image(systemName: "plus")
                    .imageScale(.large)
                    .frame(width: frame.width, height: frame.height)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("更多操作")
            .frame(width: frame.width, height: frame.height)
            .contentShape(shape)
            .position(x: frame.midX, y: frame.midY)
            .animation(.easeInOut(duration: 0.18), value: state.showsPlus)
        }

        if let frame = ComposerContextAction.trailingFrame(
            layout: layout,
            state: controller.draft.presentationState
        ) {
            switch state.primary {
            case .none:
                EmptyView()
            case .send(let enabled):
                Button {
                    Task { _ = await coordinator.handlePrimaryAction() }
                } label: {
                    Image(systemName: "arrow.up")
                        .imageScale(.large)
                        .frame(width: frame.width, height: frame.height)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("发送")
                .disabled(!enabled)
                .frame(width: frame.width, height: frame.height)
                .contentShape(shape)
                .position(x: frame.midX, y: frame.midY)
                .animation(.easeInOut(duration: 0.18), value: state.primary)
                .transition(.opacity.combined(with: .scale(scale: 0.86)))
            case .stop(_, let enabled):
                Button {
                    Task { _ = await coordinator.handlePrimaryAction() }
                } label: {
                    Image(systemName: "stop.fill")
                        .imageScale(.medium)
                        .frame(width: frame.width, height: frame.height)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("停止")
                .disabled(!enabled)
                .frame(width: frame.width, height: frame.height)
                .contentShape(shape)
                .position(x: frame.midX, y: frame.midY)
                .animation(.easeInOut(duration: 0.18), value: state.primary)
                .transition(.opacity.combined(with: .scale(scale: 0.86)))
            }
        }
    }

    @ViewBuilder
    private func composerContent(layout: ComposerLayout, shape: ConcentricRectangle) -> some View {
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
            .contentShape(shape)
            .position(x: layout.hitFrame.midX, y: layout.hitFrame.midY)
        }
    }

    private func enterEditing() {
        let event: ComposerPresentationEvent = controller.draft.presentationState == .compact
            ? .compactTapped
            : .textAreaTapped
        apply(controller.handle(event))
    }

    private func observeRunProjection() async {
        if let initial = try? await bridge.projection(conversationID) {
            runProjection = initial
            coordinator.updateRunProjection(initial)
        }
        let updates = await bridge.projectionUpdates(conversationID)
        for await projection in updates {
            runProjection = projection
            coordinator.updateRunProjection(projection)
        }
    }

    private func loadKnownModels() async {
        do {
            knownModels = try await bridge.models(controller.configuration.providerInstanceID)
                .filter { $0.providerInstanceID == controller.configuration.providerInstanceID }
        } catch {
            knownModels = []
        }
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

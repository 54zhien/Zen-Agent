import SwiftUI
import UIKit

@MainActor
struct ConversationComposerView: View {
    let conversationID: String
    @Bindable var controller: ComposerController
    private let bridge: ComposerRuntimeActionBridge
    private let onHeightChanged: (CGFloat) -> Void
    private let onMenuTopChanged: (CGFloat?) -> Void
    private let onKeyboardWillChange: () -> Void
    private let onUserFocus: () -> Void
    @State private var coordinator: ComposerSendCoordinator
    @State private var runProjection: RunProjection?
    @State private var knownModels: [ModelDescriptor] = []
    @State private var imageInputDestinationPresentation: ImageInputDestinationPresentation?
    @State private var resolvedImageInputForKey = ""
    @AppStorage(AppShellModel.imageInputInstanceIDKey) private var imageInputInstanceID = ""
    @AppStorage(AppShellModel.imageInputModelIDKey) private var imageInputModelID = ""
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.surfaceLiftController) private var lift
    @Environment(\.modelMenuPreferences) private var menuPreferences
    @Environment(\.workspaceComposerDock) private var dock

    init(conversationID: String, controller: ComposerController,
         bridge: ComposerRuntimeActionBridge, maxProviderSteps: Int,
         coordinator: ComposerSendCoordinator? = nil,
         onHeightChanged: @escaping (CGFloat) -> Void = { _ in },
         onMenuTopChanged: @escaping (CGFloat?) -> Void = { _ in },
         onKeyboardWillChange: @escaping () -> Void = {},
         onUserFocus: @escaping () -> Void = {}) {
        self.conversationID = conversationID
        self.controller = controller
        self.bridge = bridge
        self.onHeightChanged = onHeightChanged
        self.onMenuTopChanged = onMenuTopChanged
        self.onKeyboardWillChange = onKeyboardWillChange
        self.onUserFocus = onUserFocus
        _coordinator = State(initialValue: coordinator ?? ComposerSendCoordinator(
            conversationID: conversationID, controller: controller,
            configuration: controller.configuration, bridge: bridge,
            maxProviderSteps: maxProviderSteps
        ))
    }

    var body: some View {
        ComposerHostBridge(configuration: hostConfiguration,
                           focusRequested: { controller.draft.presentationState == .editing },
                           conversationID: conversationID)
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .task(id: conversationID) { await observeRunProjection() }
            .task(id: controller.configuration?.providerInstanceID) { await loadKnownModels() }
            .task(id: imageInputResolutionKey) { await loadImageInputDestination() }
#if DEBUG
            .onAppear { controller.nativeSendCoordinatorForUITest = coordinator }
            .onDisappear {
                if controller.nativeSendCoordinatorForUITest === coordinator {
                    controller.nativeSendCoordinatorForUITest = nil
                }
            }
#endif
    }

    private var selectedModel: ModelDescriptor? {
        guard let configuration = controller.configuration else { return nil }
        return knownModels.first {
            $0.providerInstanceID == configuration.providerInstanceID
                && $0.id == configuration.modelID
        }
    }

    private var selectedCapabilities: Set<ModelCapability> { selectedModel?.capabilities ?? [] }

    private var selectedImageInputTarget: ImageInputTarget? {
        guard !imageInputInstanceID.isEmpty, !imageInputModelID.isEmpty else { return nil }
        return ImageInputTarget(
            providerInstanceID: ProviderInstanceID(rawValue: imageInputInstanceID),
            modelID: ModelID(rawValue: imageInputModelID)
        )
    }

    private var imageInputResolutionKey: String {
        [imageInputInstanceID, imageInputModelID,
         controller.configuration?.providerInstanceID.rawValue ?? "",
         controller.configuration?.modelID.rawValue ?? ""].joined(separator: "\u{1f}")
    }

    private var currentImageInputDestinationPresentation: ImageInputDestinationPresentation? {
        guard resolvedImageInputForKey == imageInputResolutionKey else { return nil }
        return imageInputDestinationPresentation
    }

    private var imageInputReady: Bool {
        guard let target = selectedImageInputTarget,
              let destination = currentImageInputDestinationPresentation,
              destination.availability == .ready,
              destination.target == target,
              controller.managedImageAttachmentService != nil else { return false }
        return true
    }

    private var modelsForSelectedInstance: [ModelDescriptor] {
        guard let instanceID = controller.configuration?.providerInstanceID else { return [] }
        let canonical = knownModels.filter { $0.providerInstanceID == instanceID }
        return menuPreferences?.visibleModels(canonical) ?? canonical
    }

    private var isSendable: Bool {
        controller.sendAvailability.isReady && ComposerActionPolicy.isSendable(
            draft: controller.draft,
            capabilities: selectedCapabilities,
            quoteCommitReady: true,
            imageInputReady: imageInputReady,
            fileInputReady: false
        )
    }

    private var hostConfiguration: ComposerHostView.Configuration {
        let action = ComposerContextAction.resolve(
            projection: runProjection,
            presentationState: controller.draft.presentationState,
            sendable: isSendable,
            hasDraft: !controller.draft.text.isEmpty || !controller.draft.references.isEmpty
                || !controller.draft.attachments.isEmpty,
            plusAvailable: !modelsForSelectedInstance.isEmpty || selectedModel != nil,
            submission: coordinator.submission
        )
        let traits = UITraitCollection(
            preferredContentSizeCategory: Typography.contentSizeCategory(for: dynamicTypeSize)
        )
        return ComposerHostView.Configuration(
            text: controller.draft.text,
            selection: controller.draft.selection,
            state: controller.draft.presentationState,
            collapseProgress: controller.effectiveCollapseProgress,
            font: Typography.uiFont(for: .interfaceBody, compatibleWith: traits),
            showsPlus: action.showsPlus,
            primary: action.primary,
            models: modelsForSelectedInstance,
            selectedModelID: controller.configuration?.modelID,
            errorMessage: coordinator.sendErrorMessage ?? controller.imageAttachmentErrorMessage
                ?? controller.sendAvailability.message,
            references: controller.draft.references,
            attachments: controller.draft.attachments,
            imageInputDestinationPresentation: currentImageInputDestinationPresentation,
            managedImageAttachmentService: controller.managedImageAttachmentService,
            onRemoveQuote: controller.removeQuoteReference(id:),
            onRemoveImageAttachment: controller.removeImageAttachment(_:),
            onImageImported: controller.addImageAttachment(_:),
            onImageImportFailure: { controller.imageAttachmentErrorMessage = "图片读取失败，请重新选择。" },
            onAcceptQuote: { reference in _ = controller.addQuoteReference(reference) },
            onQuotePhase: { phase in _ = controller.handle(.quoteDragPhaseChanged(phase)) },
            onText: { text, selection, composing in
                if controller.draft.text != text { controller.draft.text = text }
                if controller.draft.selection != selection { controller.draft.selection = selection }
                if let transition = controller.updateComposition(isComposing: composing) {
                    apply(transition)
                }
            },
            onFocus: { focused in
                if focused || controller.draft.presentationState == .editing {
                    onKeyboardWillChange()
                }
                if focused {
                    onUserFocus()
                    let event: ComposerPresentationEvent = controller.draft.presentationState == .compact
                        ? .compactTapped : .textAreaTapped
                    apply(controller.handle(event))
                } else {
                    apply(controller.handle(.keyboardDismissed))
                }
            },
            onKeyboardWillChange: onKeyboardWillChange,
            onSend: { sendDraft() },
            onStop: { Task { [coordinator] in _ = await coordinator.handlePrimaryAction() } },
            onModel: { modelID in
                guard var configuration = controller.configuration,
                      let model = modelsForSelectedInstance.first(where: { $0.id == modelID }) else { return }
                configuration.selectModel(model)
                controller.configuration = configuration
            },
            onHeightChanged: { height in
                onHeightChanged(height)
                dock?.measured(height, ownerID: conversationID)
            },
            thinkingEfforts: selectedModel?.supportedThinkingEfforts ?? [],
            thinkingEffort: controller.configuration?.thinkingEffort,
            defaultThinkingEffort: selectedModel?.defaultThinkingEffort,
            onThinking: { effort in
                guard var configuration = controller.configuration else { return }
                if let effort, selectedModel?.supportedThinkingEfforts.contains(effort) != true { return }
                configuration.thinkingEffort = effort
                controller.configuration = configuration
            },
            onMenuTopChanged: { top in
                onMenuTopChanged(top)
                dock?.menuTopChanged(top, ownerID: conversationID)
            },
            skillSelectionOwner: skillSelectionOwner,
            selectedSkillIDs: controller.draft.selectedSkillIDs,
            loadSkills: { [bridge, configuration = controller.configuration] in
                try await bridge.skills(configuration?.providerInstanceID, configuration?.modelID)
            },
            onSkill: { id in
                guard let id else { controller.draft.selectedSkillIDs = []; return }
                if controller.draft.selectedSkillIDs.contains(id) {
                    controller.draft.selectedSkillIDs.removeAll { $0 == id }
                } else if controller.draft.selectedSkillIDs.count < SkillRouter.maximumActivatedSkills {
                    controller.draft.selectedSkillIDs.append(id)
                }
            },
            liftInteraction: lift.map { driver in
                ComposerLiftInteraction.Configuration(driver: driver, conversationID: conversationID) { native in
                    var input = native
                    input.isEditing = input.isEditing || controller.draft.presentationState == .editing
                    input.hasMarkedText = input.hasMarkedText || controller.isComposing
                    input.selectionActive = input.selectionActive || controller.isSelectionHandleDragging
                    input.quoteDragActive = input.quoteDragActive || controller.quoteDragPhase != .idle
                    input.composerSettled = input.composerSettled && controller.canBeginSurfaceLift(
                        keyboardVisible: input.keyboardVisible || input.keyboardTransitioning,
                        stableBottomAnchor: input.composerSettled)
                    return input
                }
            }
        )
    }

    private var skillSelectionOwner: ComposerSkillMenu.Owner {
        .init(conversationID: conversationID, target: controller.configuration)
    }

    private func loadImageInputDestination() async {
        let requestKey = imageInputResolutionKey
        guard let configuration = controller.configuration else {
            imageInputDestinationPresentation = nil
            resolvedImageInputForKey = requestKey
            return
        }
        do {
            let destination = try await bridge.imageInputDestinationPresentation(
                selectedImageInputTarget,
                configuration.providerInstanceID,
                configuration.modelID
            )
            guard !Task.isCancelled, requestKey == imageInputResolutionKey,
                  controller.configuration == configuration else { return }
            imageInputDestinationPresentation = destination
            resolvedImageInputForKey = requestKey
        } catch {
            guard !Task.isCancelled, requestKey == imageInputResolutionKey,
                  controller.configuration == configuration else { return }
            imageInputDestinationPresentation = nil
            resolvedImageInputForKey = requestKey
        }
    }

    private func sendDraft() {
        let initiatedAt = Date()
        let imageInputTarget = selectedImageInputTarget
        Task { [coordinator] in
            _ = await coordinator.handlePrimaryAction(at: initiatedAt, imageInputTarget: imageInputTarget)
        }
    }

    private func apply(_ transition: ComposerTransition) {
        // The controller publishes state; UIKit owns the one editor and follows it.
        _ = transition
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
        guard let instanceID = controller.configuration?.providerInstanceID else {
            knownModels = []
            return
        }
        do {
            let models = try await bridge.models(instanceID)
            guard controller.configuration?.providerInstanceID == instanceID else { return }
            knownModels = models.filter { $0.providerInstanceID == instanceID }
            if var configuration = controller.configuration,
               let model = knownModels.first(where: { $0.id == configuration.modelID }) {
                configuration.selectModel(model)
                controller.configuration = configuration
            }
        } catch {
            if controller.configuration?.providerInstanceID == instanceID {
                knownModels = []
            }
        }
    }
}

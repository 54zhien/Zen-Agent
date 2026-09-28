import SwiftUI
import UIKit

@MainActor
struct ConversationComposerView: View {
    let conversationID: String
    @Bindable var controller: ComposerController
    private let bridge: ComposerRuntimeActionBridge
    private let onHeightChanged: (CGFloat) -> Void
    private let onKeyboardWillChange: () -> Void
    @State private var coordinator: ComposerSendCoordinator
    @State private var runProjection: RunProjection?
    @State private var knownModels: [ModelDescriptor] = []
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(conversationID: String, controller: ComposerController,
         bridge: ComposerRuntimeActionBridge, maxProviderSteps: Int,
         onHeightChanged: @escaping (CGFloat) -> Void = { _ in },
         onKeyboardWillChange: @escaping () -> Void = {}) {
        self.conversationID = conversationID
        self.controller = controller
        self.bridge = bridge
        self.onHeightChanged = onHeightChanged
        self.onKeyboardWillChange = onKeyboardWillChange
        _coordinator = State(initialValue: ComposerSendCoordinator(
            conversationID: conversationID, controller: controller,
            configuration: controller.configuration, bridge: bridge,
            maxProviderSteps: maxProviderSteps
        ))
    }

    var body: some View {
        ComposerHostBridge(configuration: hostConfiguration,
                           focused: controller.draft.presentationState == .editing)
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .task(id: conversationID) { await observeRunProjection() }
            .task(id: controller.configuration?.providerInstanceID) { await loadKnownModels() }
    }

    private var selectedCapabilities: Set<ModelCapability> {
        guard let configuration = controller.configuration else { return [] }
        return knownModels.first {
            $0.providerInstanceID == configuration.providerInstanceID
                && $0.id == configuration.modelID
        }?.capabilities ?? []
    }

    private var modelsForSelectedInstance: [ModelDescriptor] {
        guard let instanceID = controller.configuration?.providerInstanceID else { return [] }
        return knownModels.filter { $0.providerInstanceID == instanceID }
    }

    private var isSendable: Bool {
        controller.sendAvailability.isReady && ComposerActionPolicy.isSendable(
            draft: controller.draft,
            capabilities: selectedCapabilities,
            quoteCommitReady: true,
            imageInputReady: false,
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
            plusAvailable: !modelsForSelectedInstance.isEmpty,
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
            errorMessage: coordinator.sendErrorMessage ?? controller.sendAvailability.message,
            references: controller.draft.references,
            onRemoveQuote: controller.removeQuoteReference(id:),
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
                    let event: ComposerPresentationEvent = controller.draft.presentationState == .compact
                        ? .compactTapped : .textAreaTapped
                    apply(controller.handle(event))
                } else {
                    apply(controller.handle(.keyboardDismissed))
                }
            },
            onKeyboardWillChange: onKeyboardWillChange,
            onSend: { sendDraft() },
            onStop: { Task { _ = await coordinator.handlePrimaryAction() } },
            onModel: { modelID in
                guard var configuration = controller.configuration else { return }
                configuration.modelID = modelID
                controller.configuration = configuration
            },
            onHeightChanged: onHeightChanged
        )
    }

    private func sendDraft() {
        let initiatedAt = Date()
        Task { _ = await coordinator.handlePrimaryAction(at: initiatedAt) }
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
        } catch {
            if controller.configuration?.providerInstanceID == instanceID {
                knownModels = []
            }
        }
    }
}

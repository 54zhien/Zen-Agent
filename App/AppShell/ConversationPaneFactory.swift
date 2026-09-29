import Foundation

@MainActor
struct ConversationPaneFactory {
    let sessions: ConversationSessionStore

    func makePane(
        id: String,
        initialTimeline: ConversationTimelineProjection,
        dependencies: AppAssembly.Dependencies,
        target: AppExecutionTarget?,
        snapshot: ConversationHistorySnapshot? = nil,
        onTargetFailure: @escaping @MainActor @Sendable (AppTargetFailure, AppExecutionTarget) -> Void
    ) throws -> (bridge: ComposerRuntimeActionBridge, pane: ConversationPaneController) {
        let savedSession = sessions.session(for: id)
        let configuration = try resolveConfiguration(id: id, savedSession: savedSession,
            dependencies: dependencies, target: target, snapshot: snapshot)
        let validatedAvailability = Self.availability(for: configuration, in: dependencies)
        let bridge = AppAssembly.wireConversation(
            id: id,
            dependencies: dependencies,
            onTargetFailure: onTargetFailure
        )
        // Router owns the Pane. Capturing Dependencies here would retain Router
        // through this closure and keep an idle shell's display alive indefinitely.
        let store = dependencies.store
        let preparation = dependencies.router.historyPreparation
        let pane = try ConversationPaneController(
            conversationID: id,
            initialTimeline: initialTimeline,
            configuration: configuration,
            sendAvailability: validatedAvailability,
            session: savedSession,
            coalescer: StreamingCoalescer(interval: .milliseconds(10)),
            asynchronousLoad: { id in
                try await preparation.prepare(id: id, store: store, intent: .maintenance).timeline
            }
        )
        pane.composer.sendAvailability = validatedAvailability
        return (bridge, pane)
    }

    private func resolveConfiguration(id: String, savedSession: ConversationSession?,
                                      dependencies: AppAssembly.Dependencies,
                                      target: AppExecutionTarget?,
                                      snapshot: ConversationHistorySnapshot?) throws -> ConversationComposerConfiguration? {
        if let savedSession {
            return savedSession.composer.configuration
        } else if snapshot?.conversation != nil {
            // Compatibility for history created before durable Conversation binding.
            // This is an initial choice, never a rewrite of an old frozen Run seed.
            if let seed = snapshot?.runs
                .last(where: { $0.kind == .parent })?.requestConfigSeed {
                return ConversationComposerConfiguration(
                    providerInstanceID: seed.providerInstanceID, modelID: seed.modelID)
            }
            if snapshot?.messages.isEmpty == true, snapshot?.runs.isEmpty == true,
               let binding = try dependencies.store.conversationInitialBinding(id: id),
               let instanceID = binding.providerInstanceID, let modelID = binding.modelID {
                return ConversationComposerConfiguration(providerInstanceID: instanceID, modelID: modelID)
            }
        } else {
            return target.map {
                ConversationComposerConfiguration(providerInstanceID: $0.providerInstanceID, modelID: $0.modelID)
            }
        }
        return nil
    }

    static func availability(for configuration: ConversationComposerConfiguration?,
                              in dependencies: AppAssembly.Dependencies) -> ComposerSendAvailability {
        guard let configuration else { return .unconfigured }
        do {
            _ = try AppAssembly.validateTarget(providerInstanceID: configuration.providerInstanceID,
                modelID: configuration.modelID, store: dependencies.store,
                provider: dependencies.provider, credentials: dependencies.credentials)
            return .ready
        } catch let failure as AppTargetFailure {
            return .unavailable(failure.message)
        } catch {
            return .unavailable(AppTargetFailure.configurationUnavailable.message)
        }
    }

}

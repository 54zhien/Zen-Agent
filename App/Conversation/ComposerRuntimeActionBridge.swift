import Foundation

struct ComposerRuntimeActionBridge: Sendable {
    var start: @Sendable (SendCommand) async throws -> String
    var stop: @Sendable (String) async throws -> Void
    var models: @Sendable (ProviderInstanceID) async throws -> [ModelDescriptor]
    var projection: @Sendable (String) async throws -> RunProjection?
    var projectionUpdates: @Sendable (String) async -> AsyncStream<RunProjection?>
    var skills: @Sendable (ProviderInstanceID?, ModelID?) async throws -> [ComposerSkillOption]

    init(
        start: @escaping @Sendable (SendCommand) async throws -> String,
        stop: @escaping @Sendable (String) async throws -> Void,
        models: @escaping @Sendable (ProviderInstanceID) async throws -> [ModelDescriptor],
        projection: @escaping @Sendable (String) async throws -> RunProjection?,
        projectionUpdates: @escaping @Sendable (String) async -> AsyncStream<RunProjection?>,
        skills: @escaping @Sendable (ProviderInstanceID?, ModelID?) async throws -> [ComposerSkillOption] = { _, _ in [] }
    ) {
        self.start = start
        self.stop = stop
        self.models = models
        self.projection = projection
        self.projectionUpdates = projectionUpdates
        self.skills = skills
    }

    init(runtime: ConversationRuntime) {
        start = { command in
            try await runtime.start(command)
        }
        stop = { runID in
            try await runtime.stop(runID: runID)
        }
        models = { providerInstanceID in
            try await runtime.knownModels(for: providerInstanceID)
        }
        projection = { conversationID in
            try await runtime.projection(conversationID: conversationID)
        }
        projectionUpdates = { conversationID in
            await runtime.projectionUpdates(conversationID: conversationID)
        }
        skills = { instanceID, modelID in
            try await runtime.availableSkills(providerInstanceID: instanceID, modelID: modelID)
        }
    }
}

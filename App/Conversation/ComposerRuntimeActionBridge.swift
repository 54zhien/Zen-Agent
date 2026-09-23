import Foundation

struct ComposerRuntimeActionBridge: Sendable {
    var start: @Sendable (SendCommand) async throws -> String
    var stop: @Sendable (String) async throws -> Void
    var models: @Sendable (ProviderInstanceID) async throws -> [ModelDescriptor]
    var projection: @Sendable (String) async throws -> RunProjection?
    var projectionUpdates: @Sendable (String) async -> AsyncStream<RunProjection?>

    init(
        start: @escaping @Sendable (SendCommand) async throws -> String,
        stop: @escaping @Sendable (String) async throws -> Void,
        models: @escaping @Sendable (ProviderInstanceID) async throws -> [ModelDescriptor],
        projection: @escaping @Sendable (String) async throws -> RunProjection?,
        projectionUpdates: @escaping @Sendable (String) async -> AsyncStream<RunProjection?>
    ) {
        self.start = start
        self.stop = stop
        self.models = models
        self.projection = projection
        self.projectionUpdates = projectionUpdates
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
    }
}

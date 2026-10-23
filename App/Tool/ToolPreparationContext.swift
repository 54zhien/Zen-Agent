import Foundation

/// Non-secret destination frozen by the owning Run, never by model arguments.
struct ToolPreparationContext: Sendable {
    let requestConfigSeed: RequestConfigSeed
    var destination: ToolDestinationScope {
        .provider(instanceID: requestConfigSeed.providerInstanceID.rawValue,
                  endpointIdentity: requestConfigSeed.endpoint.absoluteString)
    }
}

import Foundation

enum EmbeddingProviderFailure: Error, Equatable, Sendable {
    case unsupportedProvider
    case credentialMissing
    case credentialUnavailable
    case credentialRejected
    case requestRejected(status: Int)
    case transportFailure
    case malformedResponse
    case cancelled
}

protocol EmbeddingProvider: Sendable {
    var providerID: ProviderID { get }
    var adapterRevision: String { get }
    var modelID: String { get }
    var dimensions: Int { get }

    func embed(
        _ inputs: [String],
        instance: ProviderInstance,
        credentialBinding: CredentialBindingSnapshot,
        credentials: any CredentialStoring
    ) async throws -> [[Float]]
}

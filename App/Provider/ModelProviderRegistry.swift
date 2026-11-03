import Foundation

enum ModelProviderRegistryError: Error, Equatable, Sendable {
    case duplicateProvider(ProviderID)
    case unknownProvider(ProviderID)
    case adapterRevisionMismatch(providerID: ProviderID, requested: String, available: String)
}

/// Resolves only already-constructed Provider adapters. The Run snapshot supplies both
/// keys during execution; a registry never selects a default on a miss.
struct ModelProviderRegistry: Sendable {
    private let providersByID: [ProviderID: any ModelProvider]

    init(providers: [any ModelProvider]) throws {
        var indexed: [ProviderID: any ModelProvider] = [:]
        for provider in providers {
            guard indexed[provider.id] == nil else {
                throw ModelProviderRegistryError.duplicateProvider(provider.id)
            }
            indexed[provider.id] = provider
        }
        providersByID = indexed
    }

    init(provider: any ModelProvider) {
        providersByID = [provider.id: provider]
    }

    var providers: [any ModelProvider] {
        providersByID.values.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    func provider(for providerID: ProviderID) -> (any ModelProvider)? {
        providersByID[providerID]
    }

    func resolve(
        providerID: ProviderID,
        adapterRevision: String
    ) throws -> any ModelProvider {
        guard let provider = providersByID[providerID] else {
            throw ModelProviderRegistryError.unknownProvider(providerID)
        }
        guard provider.adapterRevision == adapterRevision else {
            throw ModelProviderRegistryError.adapterRevisionMismatch(
                providerID: providerID,
                requested: adapterRevision,
                available: provider.adapterRevision
            )
        }
        return provider
    }
}

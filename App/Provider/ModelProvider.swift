import Foundation

enum ModelCapability: String, Codable, Sendable, Hashable {
    case text
    case streaming
    case reasoning
    case vision
    case files
    case tools
}

/// Provider-owned description of one model.
///
/// Capabilities describe what Zen can actually execute through this Provider
/// adapter. They are not inferred from the model id, and upstream support that
/// the current adapter cannot encode must not be advertised here.
struct ModelDescriptor: Codable, Sendable, Equatable, Identifiable {
    var id: ModelID
    var providerInstanceID: ProviderInstanceID
    var displayName: String
    var capabilities: Set<ModelCapability>
}

/// What a Provider implementation must be able to answer.
///
/// Deliberately small. This increment establishes the seam a real adapter will slot
/// into for both model discovery and provider-neutral streaming.
///
/// One protocol, not a provider framework. The product needs several Providers, not a
/// plugin system — no type erasure layer, no registry of factories, no dependency
/// container (`开发规划.md:462-473` lists exactly that kind of pre-building as a thing
/// not to do).
protocol ModelProvider: Sendable {
    var id: ProviderID { get }

    /// Stable identity for the adapter implementation that prepared a run.
    var adapterRevision: String { get }

    /// Provider-specific instructions that belong in the frozen prompt snapshot.
    var adapterPromptInstructions: String { get }

    /// Every model this provider knows about for the instance, without network access.
    ///
    /// A remote list would be fetched by a transport and cached; this is the local
    /// knowledge a Provider has, which is also what a transport would fall back to.
    func knownModels(for instance: ProviderInstance) -> [ModelDescriptor]

    /// Resolve one model id.
    ///
    /// **Fails closed.** An unknown id returns `nil` rather than a permissive default,
    /// because the alternative is a run proceeding against a model nobody described —
    /// and the notes are explicit that unknown capability must not be guessed
    /// (`Provider 与模型.md:120`).
    func descriptor(for modelID: ModelID, in instance: ProviderInstance) -> ModelDescriptor?

    /// Freeze the provider-owned portion of a run before execution begins.
    func makeRequestConfigSeed(
        instance: ProviderInstance,
        modelID: ModelID,
        credentialBinding: CredentialBindingSnapshot
    ) throws -> RequestConfigSeed

    func stream(
        _ request: ProviderChatRequest,
        seed: RequestConfigSeed,
        credentials: any CredentialStoring
    ) async throws -> AsyncThrowingStream<ProviderStreamEvent, Error>
}

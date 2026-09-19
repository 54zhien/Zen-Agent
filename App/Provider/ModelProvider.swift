import Foundation

/// Identity and presentation of a model. **Nothing about what it can do.**
///
/// Capability modelling is its own increment, and the temptation to start it here is
/// exactly what the notes warn about: a vocabulary invented before there is a Provider
/// to validate it against becomes a vocabulary every later Provider has to be bent to
/// fit. So this carries an id, the instance it belongs to, and a name to show — and
/// stops.
///
/// The absence is load-bearing. A caller that wants to know whether a model supports
/// something has nowhere to look here, which is the correct state of affairs until
/// capability exists.
struct ModelDescriptor: Codable, Sendable, Equatable, Identifiable {
    var id: ModelID
    var providerInstanceID: ProviderInstanceID
    var displayName: String
}

/// What a Provider implementation must be able to answer.
///
/// Deliberately small. This increment establishes the seam a real adapter will slot
/// into; it has no request method, because there is no transport yet, and adding one
/// before the transport exists would mean designing it against a guess.
///
/// One protocol, not a provider framework. The product needs several Providers, not a
/// plugin system — no type erasure layer, no registry of factories, no dependency
/// container (`开发规划.md:462-473` lists exactly that kind of pre-building as a thing
/// not to do).
protocol ModelProvider: Sendable {
    var id: ProviderID { get }

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
}

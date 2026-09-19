import Foundation

/// The request configuration frozen at send commit.
///
/// A typed value rather than a free-form JSON blob. The column it lives in is a string
/// either way, but a bag would let any layer write anything into the one record whose
/// entire purpose is to be replayable — and the notes forbid exactly that
/// ("不要直接存散乱 provider raw 参数", `消息与数据.md:79`).
///
/// It lives in `App/Provider/` rather than `App/Persistence/` because it is a provider
/// concept that happens to be persisted, not a storage concept. That direction matters:
/// Persistence may reference these value types, and Provider must not reach into
/// Persistence.
///
/// **Deliberately carries no request options yet** (reasoning effort and the like).
/// Those are capability-validated, and capability arrives in its own increment.
/// Inventing an option vocabulary now would be guessing at what a Provider supports,
/// which is the thing this stage exists to find out.
struct RequestConfigSeed: Codable, Sendable, Equatable {
    var providerInstanceID: ProviderInstanceID
    var modelID: ModelID
    /// The instance's configuration revision at the moment of the freeze, so a later
    /// edit to the endpoint or provider type does not reach back into this run.
    var providerConfigRevision: ConfigRevision
    /// Non-secret generation of the credential binding. Refresh keeps it; logout,
    /// rebind or an account change must produce a new one, so a suspended run cannot
    /// silently continue on a different principal.
    var credentialBindingRevision: Int
}

extension RequestConfigSeed {
    /// Freezes the seed from an instance at the moment of send.
    ///
    /// The one place the alignment between an instance and a run's frozen configuration
    /// is expressed. Building a seed by hand elsewhere would be how the two drift: a
    /// caller that set the provider instance but filled in the revision from memory
    /// would produce a seed that no longer matches the instance it names — and the
    /// mismatch would only surface when a suspended run tried to recover.
    init(instance: ProviderInstance, modelID: ModelID, credentialBindingRevision: Int) {
        self.init(
            providerInstanceID: instance.id,
            modelID: modelID,
            providerConfigRevision: instance.configRevision,
            credentialBindingRevision: credentialBindingRevision
        )
    }
}

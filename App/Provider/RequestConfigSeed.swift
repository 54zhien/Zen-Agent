import Foundation

/// **Which credential a run was frozen against, and which generation of it.**
///
/// Both halves are required. The generation alone was the original design, and it is
/// not enough: the reference is what names *which* credential, and the instance can be
/// pointed at a different one without the generation moving at all. Freezing credential
/// A at generation 1 and then attaching a freshly provisioned credential B — also at
/// generation 1 — left every check passing while the run went out under a credential it
/// had never been frozen against.
///
/// A reference is an identifier, not material. `SecretValue` is not `Codable`, so
/// "the seed cannot carry a secret" stays a property of the types rather than a rule
/// this file has to be careful about.
struct CredentialBindingSnapshot: Codable, Sendable, Equatable {
    var reference: CredentialReference
    var generation: Int
}

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
    /// The credential identity this run was frozen against.
    ///
    /// Refresh keeps the generation; logout, rebind or an account change must produce a
    /// new one, so a suspended run cannot silently continue on a different principal.
    /// And the *reference* is frozen alongside it, so it cannot silently continue on a
    /// different credential either.
    var credentialBinding: CredentialBindingSnapshot
}

extension RequestConfigSeed {
    /// Freezes the seed from an instance at the moment of send.
    ///
    /// The one place the alignment between an instance and a run's frozen configuration
    /// is expressed. Building a seed by hand elsewhere would be how the two drift: a
    /// caller that set the provider instance but filled in the revision from memory
    /// would produce a seed that no longer matches the instance it names — and the
    /// mismatch would only surface when a suspended run tried to recover.
    ///
    /// The binding is passed in rather than derived from the instance. The instance
    /// carries a reference but not a generation — that belongs to the credential, and is
    /// read from the credential store — so a seed built from the instance alone could
    /// not contain both halves.
    init(instance: ProviderInstance, modelID: ModelID, credentialBinding: CredentialBindingSnapshot) {
        self.init(
            providerInstanceID: instance.id,
            modelID: modelID,
            providerConfigRevision: instance.configRevision,
            credentialBinding: credentialBinding
        )
    }
}

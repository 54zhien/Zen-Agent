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

    /// The format this build writes, and the only one it reads.
    ///
    /// Exists so that "written by a build that predates versioning" and "written by this
    /// build and damaged since" are different diagnoses. Without it both look like a
    /// handful of missing keys, and the only honest report is a vague one.
    static let currentFormatVersion = 1

    /// A payload this build cannot read as its own format.
    ///
    /// Three cases because they are three situations. An unversioned payload was written
    /// before versioning existed - the clean cut `P6` decided on. An unsupported one was
    /// written by a build this one does not understand, which is not corruption. And a
    /// malformed current payload was written by this build and damaged afterwards, which
    /// is the only one of the three that is a bug.
    enum FormatError: Error, Equatable {
        case unversioned
        case unsupportedVersion(Int)
        case malformedCurrentVersion(Int)
    }

    /// Written first, and read first. See `init(from:)`.
    var formatVersion: Int
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
    /// The **complete** request URL this run was frozen against, not a base URL.
    ///
    /// The endpoint was the one part of "where does this run actually go" that the seed
    /// did not record. When an instance carries no `baseURL`, the endpoint that goes out
    /// is a compile-time constant — and a constant can change between builds, so a run
    /// resumed after an update would silently go somewhere it was never frozen against.
    /// Freezing the resolved URL makes that visible instead.
    ///
    /// The provider-specific part of the resolution — which path, which default host —
    /// stays in the adapter. This stores the answer, it does not compute it.
    var endpoint: URL

    init(
        formatVersion: Int = RequestConfigSeed.currentFormatVersion,
        providerInstanceID: ProviderInstanceID,
        modelID: ModelID,
        providerConfigRevision: ConfigRevision,
        credentialBinding: CredentialBindingSnapshot,
        resolvedEndpoint: URL
    ) {
        self.formatVersion = formatVersion
        self.providerInstanceID = providerInstanceID
        self.modelID = modelID
        self.providerConfigRevision = providerConfigRevision
        self.credentialBinding = credentialBinding
        self.endpoint = resolvedEndpoint
    }

    // MARK: - Versioned coding

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case providerInstanceID
        case modelID
        case providerConfigRevision
        case credentialBinding
        case endpoint
    }

    /// Reads the version before the payload, and refuses rather than guesses.
    ///
    /// The version is decoded by hand, outside the `do` below, so a payload written
    /// before versioning is reported as *unversioned* rather than as a pile of missing
    /// keys. Everything else is then read as the current shape, and a failure there is a
    /// malformed current payload - a different thing, named differently.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        guard let version = try? container.decode(Int.self, forKey: .formatVersion) else {
            throw FormatError.unversioned
        }
        guard version == Self.currentFormatVersion else {
            throw FormatError.unsupportedVersion(version)
        }

        do {
            providerInstanceID = try container.decode(ProviderInstanceID.self, forKey: .providerInstanceID)
            modelID = try container.decode(ModelID.self, forKey: .modelID)
            providerConfigRevision = try container.decode(ConfigRevision.self, forKey: .providerConfigRevision)
            credentialBinding = try container.decode(CredentialBindingSnapshot.self, forKey: .credentialBinding)
            endpoint = try container.decode(URL.self, forKey: .endpoint)
        } catch {
            throw FormatError.malformedCurrentVersion(version)
        }
        self.formatVersion = version
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(providerInstanceID, forKey: .providerInstanceID)
        try container.encode(modelID, forKey: .modelID)
        try container.encode(providerConfigRevision, forKey: .providerConfigRevision)
        try container.encode(credentialBinding, forKey: .credentialBinding)
        try container.encode(endpoint, forKey: .endpoint)
    }
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
    /// The endpoint is passed in rather than derived here.
    ///
    /// How a provider turns an instance into a request URL is the adapter's business —
    /// which default host, which path — and a general seed that knew about
    /// `chat/completions` would be the wrong shape for the second provider. The seed
    /// records the resolved answer; `DeepSeekProvider.resolvedEndpoint(for:)` produces it.
    init(
        instance: ProviderInstance,
        modelID: ModelID,
        credentialBinding: CredentialBindingSnapshot,
        resolvedEndpoint: URL
    ) {
        self.init(
            providerInstanceID: instance.id,
            modelID: modelID,
            providerConfigRevision: instance.configRevision,
            credentialBinding: credentialBinding,
            resolvedEndpoint: resolvedEndpoint
        )
    }
}

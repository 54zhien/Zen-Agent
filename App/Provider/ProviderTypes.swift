import Foundation

/// A protocol family — DeepSeek, OpenAI, Anthropic.
///
/// A string-backed value rather than an enum: adding a Provider should not require
/// editing a type in the core, and the notes are explicit that DeepSeek is the first
/// Provider and not the product boundary (`Provider 与模型.md:20`). Backed by a string
/// rather than left as a bare `String` so a mix-up with an instance id does not compile.
struct ProviderID: RawRepresentable, Codable, Sendable, Hashable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }

    static let deepSeek = ProviderID(rawValue: "deepseek")
}

/// One connection a user has added. Same Provider, several instances, each with its own
/// credential and endpoint — that is the point of separating the two
/// (`Provider 与模型.md:47`).
struct ProviderInstanceID: RawRepresentable, Codable, Sendable, Hashable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }
}

struct ModelID: RawRepresentable, Codable, Sendable, Hashable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }
}

/// Identifies a particular configuration of an instance.
///
/// A counter, bumped by the one code path that edits an instance, rather than a
/// fingerprint of the configuration. A fingerprint would be self-maintaining, but it
/// would also mean an edit-and-revert produces the same revision — and a run frozen
/// against the old configuration would then silently match a value it was never frozen
/// against. The counter errs the other way: a reverted edit invalidates the run, which
/// is the safe direction and the cheap one to reason about.
struct ConfigRevision: RawRepresentable, Codable, Sendable, Hashable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }

    static let initial = ConfigRevision(rawValue: "1")

    /// Why a stored revision could not be advanced.
    enum FormatError: Error, Equatable {
        /// The stored value is not a counter this build knows how to count.
        case notACounter(String)
    }

    /// The revision after this one.
    ///
    /// **Fails rather than falling back.** The obvious spelling — `Int(rawValue) ?? 0` —
    /// turns anything it cannot parse into `"1"`, which is `initial`: a revision some
    /// run may already have been frozen against. An instance whose revision was
    /// unreadable would then be edited *without the revision moving off the value it
    /// collided with*, and every run frozen against that value would go on reporting a
    /// match. Refusing is the only safe direction, and the caller reports it as a typed
    /// failure rather than as a silent renumber.
    func next() throws -> ConfigRevision {
        guard let value = Int(rawValue) else {
            throw FormatError.notACounter(rawValue)
        }
        return ConfigRevision(rawValue: String(value + 1))
    }
}

/// Identifies a particular **edit state** of an instance, so a write built on a snapshot
/// something else has moved past can be refused instead of performed.
///
/// A second counter, distinct from `ConfigRevision`, because the two answer different
/// questions. `configRevision` answers *"does a run frozen against this instance still
/// match it"*, so only the mutation that changes what a run compares against may bump
/// it — `attachCredential` deliberately does not, because the credential is frozen
/// separately in the seed's `CredentialBindingSnapshot`. This answers *"is the row still
/// the one I read"*, so **every** mutation bumps it, the credential one included.
/// Reusing `configRevision` for both would have forced the credential mutation to either
/// bump a revision it must not bump, or stay invisible to concurrent control.
///
/// Backed by `Int` rather than by a string. `ConfigRevision`'s string storage is what let
/// an unparseable value decay into a reused counter; a revision that cannot hold a
/// non-number cannot repeat that.
///
/// A counter, like `ConfigRevision`, and for the same reason: a fingerprint of the row
/// would be self-maintaining, but an edit-and-revert would then produce the same value,
/// and a write built on the pre-edit snapshot would silently match again.
struct ProviderInstanceEditRevision: RawRepresentable, Codable, Sendable, Hashable {
    let rawValue: Int

    init(rawValue: Int) { self.rawValue = rawValue }

    /// Where a row starts: what the V5 migration defaults existing rows to, and what an
    /// instance that has never been edited reports.
    static let initial = ProviderInstanceEditRevision(rawValue: 0)

    var next: ProviderInstanceEditRevision {
        ProviderInstanceEditRevision(rawValue: rawValue + 1)
    }
}

/// A user-added connection to a Provider.
///
/// **Never holds a secret.** It holds a *reference* to one; the material lives in the
/// Keychain. `CredentialReference` is `Codable` and `SecretValue` is not, so this is a
/// property of the types rather than a rule this file has to be careful about.
///
/// The credential binding generation is deliberately **not** stored here. It belongs to
/// the credential, lives with it, and is read from the credential store — caching it on
/// the instance would create a second value that could drift from the real one.
struct ProviderInstance: Codable, Sendable, Equatable, Identifiable {
    var id: ProviderInstanceID
    var providerID: ProviderID
    var displayName: String
    /// Non-secret. Shown to the user, and part of what a frozen run must still match.
    var baseURL: URL?
    /// Bumped whenever any of the above changes.
    var configRevision: ConfigRevision
    /// The edit state this value was read at.
    ///
    /// Carried on the instance rather than looked up separately, because the caller that
    /// wants to edit an instance has to hand this back to the mutation: it is the whole
    /// basis for that mutation refusing a write built on a snapshot something else has
    /// since moved past. An instance assembled by hand has never been edited, so it
    /// starts where the schema starts a row.
    var editRevision: ProviderInstanceEditRevision = .initial
    /// Absent when no credential has been provisioned, or after one was removed.
    ///
    /// An instance without a credential is still a valid instance: the user's
    /// configuration outlives the secret. Deleting the credential must not delete the
    /// instance (`安全与权限.md:279` requires the reverse direction of care too —
    /// deleting an instance must not orphan a shared credential).
    var credentialReference: CredentialReference?

    /// Whether a run frozen against `seed` is still using the configuration it was
    /// frozen against.
    ///
    /// The instance id alone cannot answer this: an instance can be edited without
    /// changing its id, and the whole point of freezing a seed is that later edits do
    /// not reach back into a run that already started.
    func matches(_ seed: RequestConfigSeed) -> Bool {
        id == seed.providerInstanceID
            && configRevision == seed.providerConfigRevision
    }
}

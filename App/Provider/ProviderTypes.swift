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

    var next: ConfigRevision {
        ConfigRevision(rawValue: String((Int(rawValue) ?? 0) + 1))
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
        id.rawValue == seed.providerInstanceID
            && configRevision == seed.providerConfigRevision
    }
}

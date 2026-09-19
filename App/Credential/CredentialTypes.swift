import Foundation

/// A secret, wrapped so it cannot escape by accident.
///
/// **Deliberately not `Codable`.** That makes "the secret never reaches the database
/// or the frozen request seed" a compile error rather than a rule someone remembers —
/// `RequestConfigSeed` is `Codable`, so a `SecretValue` field simply will not fit in
/// it, and no amount of carelessness changes that.
///
/// The other three conformances exist for the same reason one layer out: a secret that
/// cannot be *stored* by accident can still be *printed* by accident. `String(describing:)`
/// on a struct reflects into its fields, so hiding the value requires `customMirror`,
/// not just a nicer `description`.
struct SecretValue: Sendable, Equatable {
    private let raw: String

    init(_ raw: String) {
        self.raw = raw
    }

    /// The only way to read it. Named so that a call site is visibly a place where a
    /// secret is being handled — greppable, and awkward enough not to be typed by
    /// accident.
    var revealed: String { raw }
}

extension SecretValue: CustomStringConvertible {
    var description: String { "<secret>" }
}

extension SecretValue: CustomDebugStringConvertible {
    var debugDescription: String { "<secret>" }
}

extension SecretValue: CustomReflectable {
    /// Empty mirror. Without this, `String(describing:)` on any containing value walks
    /// into the struct and prints the raw string — which is how secrets end up in
    /// crash logs and diagnostic dumps.
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Which kind of secret a reference points at.
///
/// Only the one kind Stage 1 needs. Access/refresh token pairs arrive with OAuth, and
/// adding cases now would be inventing a shape for a flow that does not exist.
enum CredentialKind: String, Codable, Sendable {
    case apiKey
}

/// A stable, non-secret handle for a credential.
///
/// This is what goes in the database, in the frozen request seed, and in diagnostics.
/// It identifies *which* credential without revealing anything about it.
struct CredentialReference: Codable, Sendable, Hashable {
    var id: String
    var kind: CredentialKind

    init(id: String, kind: CredentialKind = .apiKey) {
        self.id = id
        self.kind = kind
    }
}

/// Whether the credential can currently be used.
enum CredentialStatus: String, Codable, Sendable {
    /// Present and usable.
    case active
    /// A logout or an explicit invalidation happened. The user must provide it again.
    case authenticationRequired
}

/// Non-secret metadata about a stored credential. **Safe for GRDB, logs and diagnostics.**
///
/// Everything here is deliberately uninteresting: an opaque id, a counter, an optional
/// opaque fingerprint, and a status. No email, no display name, no token claims — the
/// notes forbid collecting identity details "为了诊断" that nothing needs
/// (`Provider 与模型.md:76`).
struct CredentialMetadata: Codable, Sendable, Equatable {
    var reference: CredentialReference
    /// Increments when the binding changes identity. **Not** on a token refresh.
    ///
    /// This is the number a run records in its frozen seed. Comparing it later is how a
    /// suspended run learns that its credential now belongs to a different principal —
    /// the reference string is unchanged in that case, so the string alone cannot tell.
    var bindingGeneration: Int
    /// Opaque, and only when the provider gives a stable account identity.
    var principalFingerprint: String?
    var status: CredentialStatus
    var updatedAt: Date
}

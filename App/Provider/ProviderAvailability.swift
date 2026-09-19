import Foundation

/// Why an instance can or cannot be used right now.
///
/// **Four states, none of them collapsing into another.** The requirement they exist to
/// satisfy is that "the user hasn't signed in yet", "the keychain won't open right now"
/// and "the provider rejected the credential" are different situations with different
/// responses — and that a single "login failed" would send all three down the same path.
///
/// | state | what happened | what must *not* happen |
/// |---|---|---|
/// | `credentialMissing` | nothing has been provisioned | — |
/// | `credentialTemporarilyUnavailable` | it exists but cannot be read now | **must not be treated as missing**, must not delete or re-provision |
/// | `authenticationRequired` | it was rejected, or the user logged out | must not be retried without the user acting |
/// | `available` | usable | — |
///
/// The last two both need the user to act, which is exactly why they are tempting to
/// merge — and why merging loses something. "The provider rejected this credential" is
/// evidence the token is bad; "the user logged out" is a deliberate act with a known
/// cause. Collapsing them into one value means a diagnostic cannot say which happened,
/// and a future automatic response — refresh on rejection, prompt on logout — has
/// nothing to distinguish on.
///
/// Reachability is not modelled here. There is no transport yet, and inventing network
/// states before there is a network would be designing against a guess.
enum ProviderAvailability: Sendable, Hashable {
    case available
    case credentialMissing
    /// The credential exists. It just cannot be read at this moment.
    ///
    /// A locked device during a background launch produces this, and on iOS the *only*
    /// way to learn it is to attempt a read — so the resolver below does read, and
    /// discards the result.
    case credentialTemporarilyUnavailable(reason: String)
    case authenticationRequired(reason: AuthenticationRequirementReason)

    var isUsable: Bool { self == .available }
}

/// Why the user has to act again.
///
/// Both need the same thing from them, but they are not the same event: one is evidence
/// about the credential, the other is a record of what the user did.
enum AuthenticationRequirementReason: Sendable, Hashable {
    /// The user logged out, or the local store otherwise marked it unusable.
    case loggedOut
    /// The provider refused the credential.
    ///
    /// **Evidence, not an instruction.** A rejection says the credential is not
    /// accepted; it does not authorise deleting it. Clearing a keychain entry because a
    /// server said 401 destroys the user's credential on the strength of one response,
    /// and the notes are explicit that only explicit user data operations delete
    /// (`安全与权限.md:236-247`).
    case providerRejected
}

/// Combines what the credential store knows with what the provider reports.
///
/// Two sources because the answers come from two places, and neither alone is enough:
/// the store knows whether a credential is readable, and only the provider knows whether
/// it is *accepted*. Folding them into one by trusting either alone is how a rejected
/// credential looks usable until the first request fails.
enum ProviderAvailabilityResolver {

    /// The provider's own verdict on the credential, if it has one to give.
    enum CredentialVerdict: Sendable, Equatable {
        case accepted
        /// The provider rejected it. Takes precedence over the local state: the local
        /// store cannot know a token was revoked server-side.
        case rejected
    }

    static func resolve(
        instance: ProviderInstance,
        credentials: any CredentialStoring,
        verdict: CredentialVerdict?
    ) throws -> ProviderAvailability {
        // The provider's answer wins when it has one. It is authoritative about its own
        // credential in a way local storage cannot be.
        if verdict == .rejected {
            return .authenticationRequired(reason: .providerRejected)
        }

        guard let reference = instance.credentialReference else {
            return .credentialMissing
        }

        do {
            guard try credentials.resolve(reference) != nil else {
                return .credentialMissing
            }
            return .available
        } catch let error as CredentialError {
            switch error {
            case .notFound:
                return .credentialMissing
            case .unavailable(_, let reason):
                // Translated, not collapsed. `CredentialError.unavailable` exists for
                // this distinction, and losing it one layer up would waste it.
                return .credentialTemporarilyUnavailable(reason: reason)
            case .authenticationRequired:
                return .authenticationRequired(reason: .loggedOut)
            case .alreadyExists:
                // Not reachable from a read. Reported rather than swallowed, so a
                // mis-wired call surfaces instead of looking like a missing key.
                return .authenticationRequired(reason: .loggedOut)
            }
        }
    }
}

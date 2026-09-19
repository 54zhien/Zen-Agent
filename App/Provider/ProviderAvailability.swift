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
/// | `credentialInvalid` | the provider rejected it, or the user logged out | must not be retried without the user acting |
/// | `available` | usable | — |
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
    case credentialInvalid

    var isUsable: Bool { self == .available }
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
            return .credentialInvalid
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
                return .credentialInvalid
            case .alreadyExists:
                // Not reachable from a read. Reported as invalid rather than swallowed,
                // so a mis-wired call surfaces instead of looking like a missing key.
                return .credentialInvalid
            }
        }
    }
}

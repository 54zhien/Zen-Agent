import Foundation

/// What went wrong, in Zen's vocabulary.
///
/// A Provider's raw error body may inform the message, but it never *becomes* this type
/// — a DeepSeek JSON error is a DeepSeek JSON error, and letting it reach the Runtime or
/// the UI would make every later Provider's failures a special case.
///
/// The distinctions are the point. `credentialRejected` and `insufficientBalance` are
/// both "you cannot use this right now", and they call for completely different things
/// from the user; `rateLimited` and `serverError` are both "try again", and only one of
/// them is safe to retry without thinking.
enum ProviderError: Error, Equatable {
    /// The provider refused the credential.
    ///
    /// **Evidence, not an instruction.** Nothing about this authorises deleting the
    /// stored credential, logging out, or re-provisioning: those are user actions on
    /// user data (`安全与权限.md:236-247`). All this changes is the availability
    /// judgement and the error the caller sees.
    case credentialRejected
    /// No credential has been provisioned for the instance.
    ///
    /// Distinct from `credentialRejected`: one means the user has not signed in yet, the
    /// other means what they signed in with was refused. They need the same thing from
    /// the user and are still not the same event.
    case credentialMissing
    /// The credential exists but cannot be read at this moment — a locked device, for
    /// instance.
    ///
    /// **Not** `credentialMissing`. The response to "missing" is to ask for it again; the
    /// response to this is to wait, and confusing them is how a background launch ends up
    /// destroying a valid token.
    case credentialTemporarilyUnavailable(reason: String)
    /// The request itself was malformed.
    case invalidRequest(String)
    /// The account cannot pay for the request.
    case insufficientBalance
    /// The provider rejected the parameters.
    case invalidParameters(String)
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(status: Int)
    case overloaded
    /// The request never completed.
    ///
    /// Says nothing about whether the server received it — which is exactly why the
    /// retry disposition below is not "safe to retry".
    case transportFailure(String)
    /// A response arrived but could not be understood.
    case malformedResponse(String)
    case cancelled
    /// The run's frozen configuration no longer matches the instance it names.
    ///
    /// Refused rather than resolved. A run must execute against the identity it was
    /// frozen with, not against whatever the settings screen says now.
    case configurationMismatch(String)
}

/// Whether a **higher** layer may try again.
///
/// The transport never acts on this. It exists so the decision can be made where the
/// information to make it lives — a layer that knows about attempt identity
/// (`Agent Runtime.md:342`).
enum RetryDisposition: Sendable, Equatable {
    /// The provider refused the request without processing it. Retrying is safe.
    case retryable
    /// The provider suggests trying again, but a request that reached the server may
    /// have been processed. A higher layer may retry only if it can account for that.
    case retrySuggested
    /// Retrying cannot help; something has to change first.
    case doNotRetry
}

extension ProviderError {
    var retryDisposition: RetryDisposition {
        switch self {
        case .rateLimited:
            // The provider explicitly declined to process this request, so a retry is
            // not a second generation.
            return .retryable
        case .overloaded, .serverError, .transportFailure:
            // All three mean the request *reached* something and we do not know how far
            // it got. 503 and 500 are usually "before generating", and a dropped
            // connection is usually "before arriving" — but none of that is provable
            // from here, and guessing in the permissive direction is how a POST gets
            // sent twice.
            return .retrySuggested
        case .credentialTemporarilyUnavailable:
            // A locked device unlocks. Worth trying again later — but only later, and
            // only by a layer that knows whether anything has changed.
            return .retrySuggested
        case .credentialRejected, .credentialMissing, .insufficientBalance, .invalidRequest,
             .invalidParameters, .malformedResponse, .cancelled, .configurationMismatch:
            return .doNotRetry
        }
    }
}

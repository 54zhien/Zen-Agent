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

    /// No bytes arrived within the transport's liveness window.
    ///
    /// A connection-level fact. It says nothing about whether the model was producing —
    /// a keep-alive would have reset it, and a keep-alive is not output.
    ///
    /// `deliveredOutput` is about the **model**, not the wire, and it is carried because
    /// the replay rule turns on it rather than on whether bytes moved: a stream that sent
    /// keep-alives for a minute and then died produced nothing and may be retried, while
    /// one that went quiet after two thousand tokens may not be replayed at all. Only the
    /// layer that decoded those chunks can tell the two apart, so it passes the fact in
    /// rather than letting this layer guess from byte counts.
    case streamInactivityTimeout(after: Duration, deliveredOutput: Bool)

    /// Model output stopped arriving.
    ///
    /// The other half of the same idea, and not interchangeable with the case above.
    /// This one is about the model, and it is reached even when the connection is
    /// perfectly healthy and sending heartbeats.
    case streamProgressTimeout(phase: StreamProgressPhase, after: Duration)

    /// The response stream stopped after it had begun.
    ///
    /// `deliveredOutput` is carried rather than folded away because it is the fact the
    /// replay rule turns on: once output has been delivered, re-sending the request
    /// would ask the model to generate the whole thing again while the UI still counts
    /// it as one continuous answer (`Agent Runtime.md:344`). Deciding what to do about
    /// it belongs to a layer that knows about attempts.
    ///
    /// **Output, not bytes.** The transport can say whether data moved; only the adapter
    /// can say whether any of it was the model's. A stream of keep-alive comments is
    /// bytes and is not output, and the difference decides whether a retry is allowed.
    case streamInterrupted(deliveredOutput: Bool, reason: String)
    /// The run's frozen configuration no longer matches the instance it names.
    ///
    /// Refused rather than resolved. A run must execute against the identity it was
    /// frozen with, not against whatever the settings screen says now.
    case configurationMismatch(String)
}

/// Which wait ran out.
///
/// Recorded because the two point at different situations — an inference that never
/// began, and one that stopped partway — and a caller that could not tell them apart
/// would offer the same recovery for both.
enum StreamProgressPhase: Sendable, Equatable {
    /// Nothing had been produced. The request may never have reached the model.
    case awaitingFirstEvent
    /// Output had been produced, and then stopped.
    case betweenEvents
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
        case .streamProgressTimeout(.betweenEvents, _):
            // Output existed. Replaying would ask the model to generate it again while
            // the caller still counts this as one answer (`Agent Runtime.md:344`).
            return .doNotRetry
        case .streamProgressTimeout(.awaitingFirstEvent, _):
            // Nothing was produced, and that is still not proof the request was never
            // accepted — a streaming POST cannot offer that proof
            // (`Agent Runtime.md:341-343`), so this is "cannot say" rather than "safe".
            return .retrySuggested
        case .streamInactivityTimeout(_, let deliveredOutput):
            // A liveness timeout is a fact about the wire, and the wire being quiet says
            // nothing about the answer. What matters is whether output had already been
            // handed over before it went quiet — a connection that dies two thousand
            // tokens in must not be replayed, and one that dies while the model is still
            // thinking may be attempted again.
            return deliveredOutput ? .doNotRetry : .retrySuggested
        case .streamInterrupted(let deliveredOutput, _):
            // The same rule, and the same reason the fact is carried rather than assumed.
            return deliveredOutput ? .doNotRetry : .retrySuggested
        case .credentialRejected, .credentialMissing, .insufficientBalance, .invalidRequest,
             .invalidParameters, .malformedResponse, .cancelled, .configurationMismatch:
            return .doNotRetry
        }
    }
}

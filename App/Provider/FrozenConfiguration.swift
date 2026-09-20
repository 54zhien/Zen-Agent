import Foundation

/// Checks that a run is still executing against the identity it was frozen with.
///
/// **Before dispatch, every time.** A run does not use "the configuration as it is now"
/// — it uses the one frozen at send commit, and the two diverge the moment a user edits
/// an endpoint, switches account or rotates a credential. Checking at dispatch rather
/// than at send is what catches a change made *during* the run, which is the case a
/// send-time check cannot see.
///
/// Every failure is a refusal. There is no "close enough": the alternative to refusing
/// is executing against an endpoint, a model or an account that the run was never
/// frozen against, and reporting the result as though it belonged to the original
/// request.
enum FrozenConfiguration {

    /// - Parameter resolvedEndpoint: what this instance resolves to **now**. Compared
    ///   against the frozen endpoint, which is the one the request will actually use.
    static func validate(
        seed: RequestConfigSeed,
        modelID: ModelID,
        instance: ProviderInstance,
        credentials: any CredentialStoring,
        resolvedEndpoint: URL
    ) throws {
        // **Where the run goes is part of what was frozen.** An instance with no
        // `baseURL` resolves to a compile-time default, and a constant can move between
        // builds: a run frozen before such a change would otherwise resume against a
        // host it was never frozen against, carrying its credential with it, with every
        // other check in this function still passing.
        //
        // The revision check below cannot see this. Nothing about the instance changed —
        // only the code that turns it into a URL.
        guard resolvedEndpoint == seed.endpoint else {
            throw ProviderError.configurationMismatch(
                """
                the run was frozen against \(seed.endpoint), but this instance now resolves \
                to \(resolvedEndpoint). A run executes against the endpoint it was frozen \
                with, so this one is refused rather than sent somewhere it was never \
                pointed at.
                """
            )
        }
        guard instance.id == seed.providerInstanceID else {
            throw ProviderError.configurationMismatch(
                "the run was frozen against instance \(seed.providerInstanceID.rawValue), not \(instance.id.rawValue)"
            )
        }

        guard instance.configRevision == seed.providerConfigRevision else {
            throw ProviderError.configurationMismatch(
                """
                the instance has been reconfigured since the run was frozen \
                (\(seed.providerConfigRevision.rawValue) → \(instance.configRevision.rawValue)). \
                The endpoint or provider type may have changed underneath it.
                """
            )
        }

        guard seed.modelID == modelID else {
            throw ProviderError.configurationMismatch(
                "the run was frozen against model \(seed.modelID.rawValue), not \(modelID.rawValue)"
            )
        }

        guard let reference = instance.credentialReference else {
            throw ProviderError.configurationMismatch(
                """
                the run was frozen with a credential, but the instance no longer points at \
                one. Proceeding would mean sending the request unauthenticated.
                """
            )
        }

        // Which credential. Checked before the generation, because the generation is
        // only meaningful against the credential it belongs to — comparing this
        // instance's current credential's generation against the frozen generation
        // would compare two numbers about two different credentials, and they can
        // easily agree. That was the hole: freeze A at generation 1, attach a freshly
        // provisioned B — also generation 1 — and every check passed.
        guard reference == seed.credentialBinding.reference else {
            throw ProviderError.configurationMismatch(
                """
                the instance now points at credential \(reference.id), but the run was \
                frozen against \(seed.credentialBinding.reference.id). Proceeding would \
                send the request under a credential this run was never frozen against, \
                and the two need not differ in generation for that to happen.
                """
            )
        }

        guard try credentials.matchesBinding(reference, generation: seed.credentialBinding.generation) else {
            // The reference id is unchanged across a rebind, so this is the only check
            // that can see the account move.
            throw ProviderError.configurationMismatch(
                """
                the credential binding has moved since the run was frozen \
                (generation \(seed.credentialBinding.generation)). The reference id is \
                the same, so only the generation distinguishes a rotated token from a \
                different account.
                """
            )
        }
    }
}

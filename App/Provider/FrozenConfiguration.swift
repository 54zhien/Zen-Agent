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

    static func validate(
        seed: RequestConfigSeed,
        modelID: ModelID,
        instance: ProviderInstance,
        credentials: any CredentialStoring
    ) throws {
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

        guard try credentials.matchesBinding(reference, generation: seed.credentialBindingRevision) else {
            // The reference id is unchanged across a rebind, so this is the only check
            // that can see the account move.
            throw ProviderError.configurationMismatch(
                """
                the credential binding has moved since the run was frozen \
                (generation \(seed.credentialBindingRevision)). The reference id is the \
                same, so only the generation distinguishes a rotated token from a \
                different account.
                """
            )
        }
    }
}

import Foundation

/// The identity of the adapter implementation that will execute a run.
struct AdapterIdentity: Sendable, Equatable {
    var providerID: ProviderID
    var adapterRevision: String
}

/// Checks only the execution invariants that can still change after Send.
///
/// A run uses the `RequestConfigSeed` and `RunExecutionSnapshot` captured at Send as
/// its execution truth. Ordinary edits to mutable provider settings — including display
/// name, base URL, config revision, instance credential reference, or a later model
/// choice — affect only a subsequent Parent Run. The mutable `ProviderInstance` is
/// intentionally absent from this API; do not reintroduce current-instance comparisons
/// here, because they would turn ordinary settings edits into failures for an already-
/// sent Run.
///
/// Refusal is limited to a frozen credential binding that is no longer valid and to an
/// executing adapter that is not the provider/revision named by the frozen snapshot.
enum FrozenConfiguration {

    /// Validates the dynamic validity and adapter identity of a frozen execution.
    ///
    /// Endpoint and model identity are read from the frozen seed by execution itself;
    /// this function must not compare them with mutable settings or request arguments.
    static func validate(
        seed: RequestConfigSeed,
        snapshot: RunExecutionSnapshot,
        adapter: AdapterIdentity,
        credentials: any CredentialStoring
    ) throws {
        guard adapter.providerID == snapshot.providerID else {
            throw ProviderError.configurationMismatch(
                "the run was frozen for provider \(snapshot.providerID.rawValue), but the executing adapter is \(adapter.providerID.rawValue)"
            )
        }

        guard adapter.adapterRevision == snapshot.providerAdapterRevision else {
            throw ProviderError.configurationMismatch(
                "the run was frozen against adapter revision \(snapshot.providerAdapterRevision), but the executing adapter is \(adapter.adapterRevision)"
            )
        }

        // `matchesBinding` atomically checks the frozen reference's existence, status and
        // generation. Status is judged before generation, so logout/deletion remains a
        // useful invalidation diagnosis rather than being mistaken for a mere rotation.
        guard try credentials.matchesBinding(
            seed.credentialBinding.reference,
            generation: seed.credentialBinding.generation
        ) else {
            // The reference id is unchanged across a rebind, so this is the only check
            // that can see the account move. It also catches a frozen binding that was
            // logged out or deleted.
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

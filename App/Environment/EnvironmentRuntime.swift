import Foundation

/// Trusted configuration owner. Workflow text receives prepared non-secret data only.
struct EnvironmentRuntime: Sendable {
    typealias StopRuns = @Sendable ([String]) async throws -> Void
    let store: PersistenceStore
    let credentials: any CredentialStoring
    let stopRuns: StopRuns?

    init(store: PersistenceStore, credentials: any CredentialStoring, stopRuns: StopRuns? = nil) {
        self.store = store; self.credentials = credentials; self.stopRuns = stopRuns
    }

    func list() throws -> [EnvironmentItem] { try store.environmentVariables() }

    @discardableResult
    func savePlain(id: String? = nil, expectedRevisionID: String? = nil, scope: EnvironmentScope = .global,
                   key: String, value: String) throws -> EnvironmentItem {
        try validateIdentity(scope: scope, key: key)
        guard EnvironmentValidation.allowsPlain(value) else { throw EnvironmentError.invalidValue }
        do {
            guard try SecretContentGuard.allows(value, store: store, credentials: credentials) else { throw EnvironmentError.unsafeContent }
        } catch EnvironmentError.unsafeContent { throw EnvironmentError.unsafeContent }
        catch { throw EnvironmentError.validationUnavailable }
        return try store.saveEnvironmentValue(id: id, expectedRevisionID: expectedRevisionID,
            scope: scope, key: key, value: .plain(value))
    }

    @discardableResult
    func saveSecret(id: String? = nil, expectedRevisionID: String? = nil, scope: EnvironmentScope = .global,
                    key: String, value: SecretValue) throws -> EnvironmentItem {
        try validateIdentity(scope: scope, key: key)
        guard !value.revealed.isEmpty, value.revealed.utf8.count <= EnvironmentValidation.maximumPlainUTF8Bytes,
              ToolResultGuard.isText(value.revealed) else { throw EnvironmentError.invalidValue }
        let reference = CredentialReference(id: "environment-\(UUID().uuidString)", kind: .environmentSecret)
        do { try credentials.provision(value, as: reference, principalFingerprint: nil, at: Date()) }
        catch { throw EnvironmentError.validationUnavailable }
        let binding = CredentialBindingSnapshot(reference: reference, generation: 1)
        do {
            return try store.saveEnvironmentValue(id: id, expectedRevisionID: expectedRevisionID,
                scope: scope, key: key, value: .secret(binding))
        } catch {
            let original = error
            do {
                try store.queueEnvironmentCredentialRetirement(binding)
                try retryCredentialCleanup()
            } catch {
                // A failed DB queue write must not turn a newly provisioned value
                // into an attached credential or revoke the old committed version.
                do { try credentials.logout(reference, at: Date()) }
                catch { throw EnvironmentError.cleanupPending }
            }
            throw original
        }
    }

    func resolveFrozen(_ references: [EnvironmentRevisionReference]) throws -> [EnvironmentItem] {
        let items = try store.resolveEnvironmentReferences(references)
        for item in items {
            if case .secret(let binding) = item.value {
                guard let metadata = try credentials.metadata(for: binding.reference), metadata.status == .active,
                      metadata.reference == binding.reference, metadata.bindingGeneration == binding.generation
                else { throw EnvironmentError.erasedDependency }
            }
        }
        return items
    }

    func delete(id: String) async throws {
        let runs = try await store.memoryAccessGate.withWrite { try store.beginEnvironmentDeletion(id: id) }
        if !runs.isEmpty {
            guard let stopRuns else { throw EnvironmentError.resourceInUse }
            do { try await stopRuns(runs) } catch { throw EnvironmentError.resourceInUse }
        }
        try await store.memoryAccessGate.withWrite { try store.finishEnvironmentDeletion(id: id) }
        try retryCredentialCleanup()
    }

    func retryCredentialCleanup() throws {
        var pending = false
        for binding in try store.pendingEnvironmentCredentialRetirements() {
            do {
                if try !store.environmentCredentialIsReferenced(binding.reference),
                   let metadata = try credentials.metadata(for: binding.reference), metadata.status == .active,
                   metadata.bindingGeneration == binding.generation {
                    try credentials.logout(binding.reference, at: Date())
                }
                try store.completeEnvironmentCredentialRetirement(binding)
            } catch { pending = true }
        }
        if pending { throw EnvironmentError.cleanupPending }
    }

    private func validateIdentity(scope: EnvironmentScope, key: String) throws {
        guard EnvironmentValidation.allowsKey(key) else { throw EnvironmentError.invalidKey }
        guard try store.environmentScopeExists(scope) else { throw EnvironmentError.invalidScope }
    }
}

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

    func dependencies(id: String) throws -> ExtensionDependencySummary {
        let variables = try list()
        guard let item = variables.first(where: { $0.id == id }) else { throw EnvironmentError.notFound }
        let names = try store.skills().filter { skill in
            guard skill.definition.environmentKeys.contains(item.key) else { return false }
            if let owner = item.scope.skillID { return owner == skill.id }
            return !variables.contains { $0.scope == .skill(skill.id) && $0.key == item.key }
        }.map { $0.definition.name }
        return .init(skillNames: names.sorted(), activeRunIDs: try store.environmentDependentRunIDs(id: id))
    }

    func pendingCleanupCount() throws -> Int { try store.pendingEnvironmentCredentialRetirements().count }

    @discardableResult
    func savePlain(id: String? = nil, expectedRevisionID: String? = nil, scope: EnvironmentScope = .global,
                   key: String, value: String) throws -> EnvironmentItem {
        try store.memoryAccessGate.environmentCredentialLock.withLock {
            try validateIdentity(scope: scope, key: key)
            guard EnvironmentValidation.allowsPlain(value) else { throw EnvironmentError.invalidValue }
            do {
                guard try SecretContentGuard.allows(value, store: store, credentials: credentials) else { throw EnvironmentError.unsafeContent }
            } catch EnvironmentError.unsafeContent { throw EnvironmentError.unsafeContent }
            catch { throw EnvironmentError.validationUnavailable }
            return try store.saveEnvironmentValue(id: id, expectedRevisionID: expectedRevisionID,
                scope: scope, key: key, value: .plain(value))
        }
    }

    @discardableResult
    func saveSecret(id: String? = nil, expectedRevisionID: String? = nil, scope: EnvironmentScope = .global,
                    key: String, value: SecretValue) async throws -> EnvironmentItem {
        try await store.memoryAccessGate.withWrite {
            try Task.checkCancellation()
            return try store.memoryAccessGate.environmentCredentialLock.withLock {
                try saveSecretLocked(id: id, expectedRevisionID: expectedRevisionID, scope: scope, key: key, value: value)
            }
        }
    }

    private func saveSecretLocked(id: String?, expectedRevisionID: String?, scope: EnvironmentScope,
                                  key: String, value: SecretValue) throws -> EnvironmentItem {
        try validateIdentity(scope: scope, key: key)
        guard !value.revealed.isEmpty, value.revealed.utf8.count <= EnvironmentValidation.maximumPlainUTF8Bytes,
              ToolResultGuard.isText(value.revealed) else { throw EnvironmentError.invalidValue }
        let reference = CredentialReference(id: "environment-\(UUID().uuidString)", kind: .environmentSecret)
        let binding = CredentialBindingSnapshot(reference: reference, generation: 1)

        do {
            guard try credentials.metadata(for: reference) == nil else {
                throw CredentialError.alreadyExists(reference)
            }
        } catch CredentialError.alreadyExists(let existing) where existing == reference {
            throw EnvironmentError.validationUnavailable
        } catch {
            throw EnvironmentError.validationUnavailable
        }

        do { try store.queueEnvironmentCredentialRetirement(binding) }
        catch { throw EnvironmentError.cleanupPending }

        do {
            try credentials.provision(value, as: reference, principalFingerprint: nil, at: Date())
        } catch CredentialError.alreadyExists(let existing) where existing == reference {
            do { try store.completeEnvironmentCredentialRetirement(binding) }
            catch { throw EnvironmentError.cleanupPending }
            throw EnvironmentError.validationUnavailable
        } catch {
            do {
                try retryCredentialCleanup()
            } catch { throw EnvironmentError.cleanupPending }
            throw EnvironmentError.validationUnavailable
        }

        do {
            return try store.saveEnvironmentValue(id: id, expectedRevisionID: expectedRevisionID,
                scope: scope, key: key, value: .secret(binding), clearingCredentialRetirement: binding)
        } catch {
            let original = error
            do { try retryCredentialCleanup() }
            catch { throw EnvironmentError.cleanupPending }
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
        try store.memoryAccessGate.environmentCredentialLock.withLock { try cleanupCredentialsLocked() }
    }

    private func cleanupCredentialsLocked() throws {
        try store.queueUnattachedEnvironmentCredentials()
        var pending = false
        for binding in try store.pendingEnvironmentCredentialRetirements() {
            do {
                if try !store.environmentCredentialIsReferenced(binding.reference) {
                    try credentials.retireOwnedEnvironmentSecret(
                        reference: binding.reference,
                        generation: binding.generation,
                        at: Date()
                    )
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

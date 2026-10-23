import Foundation

/// Owns Memory business writes; storage, UI and Prompt assembly do not infer facts.
struct MemoryRuntime: Sendable {
    let store: PersistenceStore
    let credentials: (any CredentialStoring)?
    static let automaticFormationAvailable = false

    @discardableResult
    func save(id: String? = nil, expectedRevisionID: String? = nil, content: String) throws -> MemoryItem {
        try validate(content)
        return try store.saveMemory(id: id, expectedRevisionID: expectedRevisionID, content: content)
    }

    func validate(_ content: String) throws {
        guard MemoryContentPolicy.allows(content) else { throw MemoryError.unsafeContent }
        let secrets: [SecretValue]
        do { secrets = try knownSecrets() } catch { throw MemoryError.validationUnavailable }
        let result = ToolResultGuard.sanitize(ToolExecutionResult(content: content), knownSecrets: secrets)
        guard result.failure == nil, result.content.utf8.elementsEqual(content.utf8) else { throw MemoryError.unsafeContent }
    }

    func setEnabled(_ enabled: Bool) throws { try store.setMemoryEnabled(enabled) }
    func setAutomatic(_ enabled: Bool) throws {
        guard Self.automaticFormationAvailable else { throw MemoryError.validationUnavailable }
        try store.setMemoryAutomatic(enabled)
    }
    func delete(id: String) async throws {
        try await MemoryAccessGate.shared.withWrite { try store.deleteMemory(id: id) }
    }
    func clear() async throws {
        try await MemoryAccessGate.shared.withWrite { try store.clearMemory() }
    }

    private func knownSecrets() throws -> [SecretValue] {
        let references = Set(try store.providerInstances().compactMap(\.credentialReference))
        guard let credentials else {
            guard references.isEmpty else { throw MemoryError.validationUnavailable }
            return []
        }
        var result: [SecretValue] = []
        for reference in references {
            guard let metadata = try credentials.metadata(for: reference) else { throw MemoryError.validationUnavailable }
            if metadata.status == .active {
                guard let secret = try credentials.resolve(reference) else { throw MemoryError.validationUnavailable }
                result.append(secret)
            }
        }
        return result
    }
}

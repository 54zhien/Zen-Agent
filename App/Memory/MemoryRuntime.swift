import Foundation

/// Owns Memory business writes; storage, UI and Prompt assembly do not infer facts.
struct MemoryRuntime: Sendable {
    let store: PersistenceStore
    let credentials: (any CredentialStoring)?
    static let automaticFormationAvailable = true

    func formAfterCompletedRun(runID: String) {
        do {
            guard let input = try store.prepareMemoryFormation(runID: runID) else { return }
            try store.memoryAccessGate.environmentCredentialLock.withLock {
                let candidates: [MemoryCandidate]
                do {
                    // Check the full source before canonicalization can hide a known
                    // credential or turn an unsafe fragment into an innocent fact.
                    try validate(input.text, maximumUTF8Bytes: MemoryCandidateExtractor.maximumSourceUTF8Bytes)
                    candidates = MemoryCandidateExtractor.extract(input.text)
                    for candidate in candidates { try validate(candidate.content) }
                } catch {
                    try store.commitMemoryCandidates([], from: input)
                    return
                }
                try store.commitMemoryCandidates(candidates, from: input)
            }
        } catch {
            // Memory is best effort. Neither raw source nor credential failures
            // belong in diagnostics, and the completed Run keeps its outcome.
        }
    }

    func retrieve(query: String) -> [MemoryContext] {
        do {
            guard try store.memorySettings().enabled else { return [] }
            let selected = MemoryRetriever.select(query: query, records: try store.memories(activeOnly: true))
            return try selected.map { item in
                try validate(item.content)
                return MemoryContext(reference: item.reference, content: item.content)
            }
        } catch { return [] }
    }

    func resolveFrozen(_ references: [MemoryRevisionReference]) throws -> [MemoryContext] {
        let contexts = try store.resolveMemoryReferences(references)
        for context in contexts { try validate(context.content) }
        return contexts
    }

    @discardableResult
    func save(id: String? = nil, expectedRevisionID: String? = nil, content: String) throws -> MemoryItem {
        try store.memoryAccessGate.environmentCredentialLock.withLock {
            try validate(content)
            return try store.saveMemory(id: id, expectedRevisionID: expectedRevisionID, content: content)
        }
    }

    func validate(_ content: String, maximumUTF8Bytes: Int = MemoryContentPolicy.maximumUTF8Bytes) throws {
        guard MemoryContentPolicy.allows(content, maximumUTF8Bytes: maximumUTF8Bytes) else { throw MemoryError.unsafeContent }
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
        try await store.memoryAccessGate.withWrite { try store.deleteMemory(id: id) }
    }
    func clear() async throws {
        try await store.memoryAccessGate.withWrite { try store.clearMemory() }
    }

    private func knownSecrets() throws -> [SecretValue] {
        try SecretContentGuard.knownSecrets(store: store, credentials: credentials)
    }
}

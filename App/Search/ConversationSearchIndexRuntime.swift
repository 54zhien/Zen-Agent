import CryptoKit
import Foundation

enum ConversationSemanticSearchFailure: Error, Equatable, Sendable {
    case providerUnavailable
    case accountUnavailable
    case credentialMissing
    case credentialUnavailable
    case credentialRejected
    case queryTooLong
    case storageUnavailable
    case providerRequestFailed
    case invalidEmbedding
}

struct ConversationSearchChunk: Equatable, Sendable {
    let conversationID: String
    let partID: String
    let chunkIndex: Int
    let startOffset: Int
    let endOffset: Int
    let sourceRevision: Int64
    let contentHash: String
    let text: String

    var key: ConversationSearchChunkKey {
        ConversationSearchChunkKey(partID: partID, chunkIndex: chunkIndex)
    }
}

struct ConversationSearchChunkKey: Hashable, Sendable {
    let partID: String
    let chunkIndex: Int
}

enum ConversationSearchChunker {
    static let maximumUTF8Bytes = 2_048
    private static let overlapScalars = 96

    static func chunks(from source: ConversationSearchSource) -> [ConversationSearchChunk] {
        let scalars = Array(source.text.unicodeScalars)
        guard !scalars.isEmpty else { return [] }

        var chunks: [ConversationSearchChunk] = []
        var start = 0
        while start < scalars.count {
            var end = start
            var byteCount = 0
            while end < scalars.count {
                let nextBytes = scalars[end].utf8.count
                guard byteCount + nextBytes <= maximumUTF8Bytes else { break }
                byteCount += nextBytes
                end += 1
            }
            if end == start { end += 1 }

            let text = String(String.UnicodeScalarView(scalars[start..<end]))
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chunks.append(ConversationSearchChunk(
                    conversationID: source.conversationID,
                    partID: source.partID,
                    chunkIndex: chunks.count,
                    startOffset: start,
                    endOffset: end,
                    sourceRevision: source.sourceRevision,
                    contentHash: hash(text),
                    text: text
                ))
            }
            guard end < scalars.count else { break }
            start = max(start + 1, end - overlapScalars)
        }
        return chunks
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct ConversationSearchIndexRuntime: Sendable {
    private let store: PersistenceStore
    private let embeddingProvider: any EmbeddingProvider
    private let credentials: any CredentialStoring

    init(store: PersistenceStore, embeddingProvider: any EmbeddingProvider,
         credentials: any CredentialStoring) {
        self.store = store
        self.embeddingProvider = embeddingProvider
        self.credentials = credentials
    }

    func search(query rawQuery: String, providerInstanceID: ProviderInstanceID) async throws -> ConversationSearchPage {
        try Task.checkCancellation()
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return ConversationSearchPage(items: [], nextCursor: nil) }
        guard query.utf8.count <= ConversationSearchChunker.maximumUTF8Bytes else {
            throw ConversationSemanticSearchFailure.queryTooLong
        }
        guard embeddingProvider.providerID == .openAI else {
            throw ConversationSemanticSearchFailure.providerUnavailable
        }

        let instance: ProviderInstance
        do {
            guard let stored = try store.providerInstance(id: providerInstanceID),
                  stored.providerID == embeddingProvider.providerID else {
                throw ConversationSemanticSearchFailure.accountUnavailable
            }
            instance = stored
        } catch let failure as ConversationSemanticSearchFailure {
            throw failure
        } catch {
            throw ConversationSemanticSearchFailure.storageUnavailable
        }

        guard let reference = instance.credentialReference else {
            throw ConversationSemanticSearchFailure.credentialMissing
        }
        let binding: CredentialBindingSnapshot
        do {
            guard let metadata = try credentials.metadata(for: reference) else {
                throw ConversationSemanticSearchFailure.credentialMissing
            }
            guard metadata.status == .active else {
                throw ConversationSemanticSearchFailure.credentialRejected
            }
            binding = CredentialBindingSnapshot(
                reference: metadata.reference,
                generation: metadata.bindingGeneration
            )
        } catch let failure as ConversationSemanticSearchFailure {
            throw failure
        } catch let error as CredentialError {
            switch error {
            case .notFound:
                throw ConversationSemanticSearchFailure.credentialMissing
            case .authenticationRequired, .bindingMoved:
                throw ConversationSemanticSearchFailure.credentialRejected
            case .unavailable, .failed, .alreadyExists:
                throw ConversationSemanticSearchFailure.credentialUnavailable
            }
        } catch {
            throw ConversationSemanticSearchFailure.credentialUnavailable
        }

        let sources: [ConversationSearchSource]
        do {
            sources = try store.conversationSearchSources()
        } catch {
            throw ConversationSemanticSearchFailure.storageUnavailable
        }
        let chunks = sources.flatMap(ConversationSearchChunker.chunks)
        guard !chunks.isEmpty else { return ConversationSearchPage(items: [], nextCursor: nil) }

        let profileID = Self.profileID(for: embeddingProvider, instance: instance)
        let existing: [ConversationVectorRecord]
        do {
            existing = try store.conversationVectorRecords(profileID: profileID)
        } catch {
            throw ConversationSemanticSearchFailure.storageUnavailable
        }
        let existingByKey = Dictionary(uniqueKeysWithValues: existing.map { ($0.key, $0) })
        let missing = chunks.filter { chunk in
            guard let record = existingByKey[chunk.key] else { return true }
            return record.sourceRevision != chunk.sourceRevision || record.contentHash != chunk.contentHash
        }

        try Task.checkCancellation()
        let queryVector = try await embedQueryAndMissingChunks(
            query,
            missing: missing,
            profileID: profileID,
            instance: instance,
            binding: binding
        )
        try Task.checkCancellation()
        let vectors: [ConversationVectorRecord]
        do {
            vectors = try store.conversationVectorRecords(profileID: profileID)
        } catch {
            throw ConversationSemanticSearchFailure.storageUnavailable
        }

        let chunkByKey = Dictionary(uniqueKeysWithValues: chunks.map { ($0.key, $0) })
        var bestMatchByConversation: [String: (score: Float, chunk: ConversationSearchChunk)] = [:]
        for record in vectors {
            guard let chunk = chunkByKey[record.key],
                  chunk.sourceRevision == record.sourceRevision,
                  chunk.contentHash == record.contentHash,
                  let score = Self.cosineSimilarity(queryVector, record.embedding) else { continue }
            if let previous = bestMatchByConversation[record.conversationID], previous.score >= score { continue }
            bestMatchByConversation[record.conversationID] = (score, chunk)
        }

        let ranked = bestMatchByConversation.sorted { lhs, rhs in
            lhs.value.score == rhs.value.score ? lhs.key < rhs.key : lhs.value.score > rhs.value.score
        }
        let summaries: [ConversationSummary]
        do {
            summaries = try store.conversationSummaryWindow(ids: ranked.map(\.key), limit: 50)
        } catch {
            throw ConversationSemanticSearchFailure.storageUnavailable
        }
        let summaryByID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })
        let items = ranked.compactMap { entry -> ConversationSearchResult? in
            guard let summary = summaryByID[entry.key] else { return nil }
            let excerpt = entry.value.chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return ConversationSearchResult(
                summary: summary,
                matchSnippet: String(excerpt.prefix(180))
            )
        }
        return ConversationSearchPage(items: Array(items.prefix(50)), nextCursor: nil)
    }

    private func embedQueryAndMissingChunks(
        _ query: String,
        missing: [ConversationSearchChunk],
        profileID: String,
        instance: ProviderInstance,
        binding: CredentialBindingSnapshot
    ) async throws -> [Float] {
        try Task.checkCancellation()
        let firstBatch = Array(missing.prefix(63))
        let firstInputs = [query] + firstBatch.map(\.text)
        let firstVectors = try await embed(firstInputs, instance: instance, binding: binding)
        guard firstVectors.count == firstInputs.count,
              let queryVector = firstVectors.first else {
            throw ConversationSemanticSearchFailure.invalidEmbedding
        }
        try Task.checkCancellation()
        try save(firstBatch, vectors: Array(firstVectors.dropFirst()), profileID: profileID)

        var offset = firstBatch.count
        while offset < missing.count {
            try Task.checkCancellation()
            let end = min(offset + 64, missing.count)
            let batch = Array(missing[offset..<end])
            let vectors = try await embed(batch.map(\.text), instance: instance, binding: binding)
            try Task.checkCancellation()
            try save(batch, vectors: vectors, profileID: profileID)
            offset = end
        }
        return queryVector
    }

    private func embed(_ inputs: [String], instance: ProviderInstance,
                       binding: CredentialBindingSnapshot) async throws -> [[Float]] {
        try Task.checkCancellation()
        do {
            let vectors = try await embeddingProvider.embed(
                inputs,
                instance: instance,
                credentialBinding: binding,
                credentials: credentials
            )
            try Task.checkCancellation()
            guard vectors.count == inputs.count,
                  vectors.allSatisfy({ $0.count == embeddingProvider.dimensions && $0.allSatisfy(\.isFinite) }) else {
                throw ConversationSemanticSearchFailure.invalidEmbedding
            }
            return vectors
        } catch let failure as ConversationSemanticSearchFailure {
            throw failure
        } catch let failure as EmbeddingProviderFailure {
            switch failure {
            case .unsupportedProvider:
                throw ConversationSemanticSearchFailure.providerUnavailable
            case .credentialMissing:
                throw ConversationSemanticSearchFailure.credentialMissing
            case .credentialUnavailable:
                throw ConversationSemanticSearchFailure.credentialUnavailable
            case .credentialRejected:
                throw ConversationSemanticSearchFailure.credentialRejected
            case .malformedResponse:
                throw ConversationSemanticSearchFailure.invalidEmbedding
            case .cancelled:
                throw CancellationError()
            case .requestRejected, .transportFailure:
                throw ConversationSemanticSearchFailure.providerRequestFailed
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ConversationSemanticSearchFailure.providerRequestFailed
        }
    }

    private func save(_ chunks: [ConversationSearchChunk], vectors: [[Float]], profileID: String) throws {
        guard chunks.count == vectors.count else { throw ConversationSemanticSearchFailure.invalidEmbedding }
        let records = zip(chunks, vectors).map { chunk, vector in
            ConversationVectorRecord(profileID: profileID, chunk: chunk, embedding: vector)
        }
        do {
            try store.saveConversationVectorRecords(records)
        } catch {
            throw ConversationSemanticSearchFailure.storageUnavailable
        }
    }

    private static func profileID(for provider: any EmbeddingProvider, instance: ProviderInstance) -> String {
        [provider.providerID.rawValue, provider.adapterRevision, instance.id.rawValue,
         instance.configRevision.rawValue, provider.modelID, String(provider.dimensions)].joined(separator: "|")
    }

    private static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float? {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return nil }
        var dot: Float = 0
        var lhsNorm: Float = 0
        var rhsNorm: Float = 0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            lhsNorm += lhs[index] * lhs[index]
            rhsNorm += rhs[index] * rhs[index]
        }
        guard lhsNorm > 0, rhsNorm > 0 else { return nil }
        return dot / (lhsNorm.squareRoot() * rhsNorm.squareRoot())
    }
}

private extension ConversationVectorRecord {
    var key: ConversationSearchChunkKey {
        ConversationSearchChunkKey(partID: partID, chunkIndex: chunkIndex)
    }
}

import Foundation
import GRDB

extension PersistenceStore {
    func prepareMemoryFormation(runID: String) throws -> MemoryFormationInput? {
        try database.read { try Self.prepareMemoryFormation(runID: runID, db: $0) }
    }

    func commitMemoryCandidates(_ candidates: [MemoryCandidate], from input: MemoryFormationInput) throws {
        guard candidates.count <= MemoryCandidateExtractor.maximumCandidates,
              candidates.allSatisfy({ MemoryContentPolicy.allows($0.content) &&
                  ($0.origin == .automatic || $0.origin == .explicitUser) && $0.factKey != nil })
        else { throw MemoryError.unsafeContent }
        try database.write { db in
            // Re-read the actual source and settings in the committing write. A
            // captured candidate carries no authority across clear/disable/edit.
            guard let current = try Self.prepareMemoryFormation(runID: input.runID, db: db),
                  current.generation == input.generation,
                  current.messageID == input.messageID, current.conversationID == input.conversationID,
                  current.sourceCreatedAt == input.sourceCreatedAt,
                  current.text.utf8.elementsEqual(input.text.utf8) else { return }
            let now = Date()
            for candidate in candidates { try Self.mergeMemoryCandidate(candidate, from: current, db: db, at: now) }
            try db.execute(sql: "INSERT INTO memoryExtractionReceipt(messageID,createdAt) VALUES (?,?)", arguments: [current.messageID, now])
        }
    }

    private static func prepareMemoryFormation(runID: String, db: Database) throws -> MemoryFormationInput? {
        let settings = try memorySettings(db)
        guard settings.enabled, settings.automaticEnabled,
              let run = try AgentRunRecord.fetchOne(db, key: runID), run.kind == .parent, run.state == .completed,
              let messageID = run.triggerMessageID,
              let message = try MessageRecord.fetchOne(db, key: messageID), message.role == .user,
              message.conversationID == run.conversationID,
              try ConversationRecord.fetchOne(db, key: run.conversationID)?.lifecycle == .visible,
              let row = try Row.fetchOne(db, sql: "SELECT extractionCutoff FROM memorySettings WHERE id = 'global'")
        else { return nil }
        let cutoff: Date = row["extractionCutoff"]
        guard message.createdAt > cutoff,
              try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM memoryExtractionReceipt WHERE messageID = ?)", arguments: [messageID]) == false
        else { return nil }
        let parts = try MessagePartRecord.fetchAll(db, sql: "SELECT * FROM messagePart WHERE messageID = ? ORDER BY sequence", arguments: [messageID])
        guard !parts.isEmpty, parts.allSatisfy({ $0.kind == .text && $0.state == .completed }) else { return nil }
        let text = try parts.map { try JSONDecoder().decode(TextPartPayload.self, from: Data($0.payload.utf8)).text }.joined(separator: "\n")
        guard text.utf8.count <= MemoryCandidateExtractor.maximumSourceUTF8Bytes else { return nil }
        return MemoryFormationInput(runID: runID, conversationID: run.conversationID, messageID: messageID,
            text: text, sourceCreatedAt: message.createdAt, generation: settings.generation)
    }

    private static func mergeMemoryCandidate(_ candidate: MemoryCandidate, from input: MemoryFormationInput,
        db: Database, at now: Date) throws {
        let records = try MemoryRecord.fetchAll(db, sql: "SELECT * FROM memoryRecord WHERE state = 'active' ORDER BY id")
        let items = try records.map { try memoryItem($0, db: db) }
        let source = MemorySource(id: UUID().uuidString, conversationID: input.conversationID,
            messageID: input.messageID, kind: candidate.origin, missing: false)
        let duplicates = items.filter { normalizedMemoryFact($0.content) == normalizedMemoryFact(candidate.content) }
        if let duplicate = duplicates.first {
            try addMemorySource(source, memoryID: duplicate.id, db: db, at: input.sourceCreatedAt)
            try db.execute(sql: "UPDATE memoryRecord SET updatedAt = ? WHERE id = ?", arguments: [now, duplicate.id])
            return
        }
        let matching = items.filter { $0.factKey == candidate.factKey }
        guard matching.count <= 1 else { return }
        let item: MemoryItem
        if let existing = matching.first {
            guard existing.origin == .automatic || existing.origin == .explicitUser else { return }
            let row = try Row.fetchOne(db, sql: "SELECT MAX(createdAt) AS observedAt FROM memorySource WHERE memoryID = ?", arguments: [existing.id])
            let observedAt: Date? = row?["observedAt"]
            // Completion order across Conversations is not assertion order.
            if let observedAt, input.sourceCreatedAt <= observedAt { return }
            item = try saveMemory(db, id: existing.id, expectedRevisionID: existing.revisionID, content: candidate.content,
                origin: candidate.origin, factKey: candidate.factKey, source: nil, at: now)
        } else {
            item = try saveMemory(db, id: nil, expectedRevisionID: nil, content: candidate.content,
                origin: candidate.origin, factKey: candidate.factKey, source: nil, at: now)
        }
        try addMemorySource(source, memoryID: item.id, db: db, at: input.sourceCreatedAt)
    }

    private static func normalizedMemoryFact(_ content: String) -> String {
        MemoryRetriever.normalized(content).filter { !$0.isWhitespace && !$0.isPunctuation }
    }
}

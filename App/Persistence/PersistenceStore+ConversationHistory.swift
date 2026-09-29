import Foundation
import GRDB

/// Records from one read transaction. No connection escapes into presentation code.
struct ConversationHistorySnapshot: Sendable {
    let conversation: ConversationRecord?
    let runs: [AgentRunRecord]
    let messages: [MessageRecord]
    let parts: [MessagePartRecord]
    let calls: [ToolCallRecord]
    let results: [ToolResultRecord]
    let quotes: [MessageQuoteReferenceRecord]
    let availableQuoteIDs: Set<String>
}

extension PersistenceStore {
    func conversationHistory(id: String) throws -> ConversationHistorySnapshot {
        try database.read { try Self.readConversationHistory(id: id, db: $0) }
    }

    func conversationHistoryAsync(id: String) async throws -> ConversationHistorySnapshot {
        try await database.readAsync { try Self.readConversationHistory(id: id, db: $0) }
    }

    private static func readConversationHistory(id: String, db: Database) throws -> ConversationHistorySnapshot {
        try Task.checkCancellation()
        let conversation = try ConversationRecord.fetchOne(db, key: id)
        let runs = try AgentRunRecord.filter(Column("conversationID") == id)
            .order(Column("createdAt").asc, Column("id").asc).fetchAll(db)
        try Task.checkCancellation()
        let messages = try MessageRecord.filter(Column("conversationID") == id).fetchAll(db)
        try Task.checkCancellation()
        // Joins avoid both N+1 reads and SQLite's bind-parameter limit for long histories.
        let parts = try MessagePartRecord.fetchAll(db, sql: """
            SELECT p.* FROM messagePart p JOIN message m ON m.id = p.messageID
            WHERE m.conversationID = ? ORDER BY p.messageID, p.sequence, p.id
            """, arguments: [id])
        try Task.checkCancellation()
        let calls = try ToolCallRecord.fetchAll(db, sql: """
            SELECT c.* FROM toolCall c JOIN agentRun r ON r.id = c.agentRunID
            WHERE r.conversationID = ? AND r.kind = 'parent'
            """, arguments: [id])
        try Task.checkCancellation()
        let results = try ToolResultRecord.fetchAll(db, sql: """
            SELECT t.* FROM toolResult t JOIN toolCall c ON c.id = t.toolCallID
            JOIN agentRun r ON r.id = c.agentRunID
            WHERE r.conversationID = ? AND r.kind = 'parent'
            """, arguments: [id])
        try Task.checkCancellation()
        let quotes = try MessageQuoteReferenceRecord.fetchAll(db, sql: """
            SELECT q.* FROM messageQuoteReference q JOIN message m ON m.id = q.messageID
            WHERE m.conversationID = ? ORDER BY q.messageID, q.sequence, q.id
            """, arguments: [id])
        try Task.checkCancellation()
        let available = try String.fetchAll(db, sql: """
            SELECT q.id FROM messageQuoteReference q
            JOIN message target ON target.id = q.messageID
            JOIN message source ON source.id = q.sourceMessageID
                AND source.conversationID = q.sourceConversationID
            JOIN messagePart p ON p.id = q.sourcePartID AND p.messageID = source.id
            WHERE target.conversationID = ? AND p.kind = 'text' AND p.state = 'completed'
            """, arguments: [id])
        try Task.checkCancellation()
        return ConversationHistorySnapshot(conversation: conversation, runs: runs, messages: messages,
            parts: parts, calls: calls, results: results, quotes: quotes, availableQuoteIDs: Set(available))
    }
}

import Foundation
import GRDB

extension PersistenceStore {
    func conversationVectorRecords(profileID: String) throws -> [ConversationVectorRecord] {
        try database.read { db in
            try ConversationVectorRecord.fetchAll(db, sql: """
                SELECT vector.*
                FROM conversationSearch.conversationVectorRecord AS vector
                JOIN main.conversation ON conversation.id = vector.conversationID
                JOIN main.messagePart AS part ON part.id = vector.partID
                JOIN main.message ON message.id = part.messageID
                    AND message.conversationID = conversation.id
                JOIN main.conversationSearchPartState AS partState ON partState.partID = part.id
                WHERE vector.profileID = ?
                  AND vector.sourceRevision = partState.revision
                  AND conversation.lifecycle = 'visible'
                  AND message.role IN ('user', 'assistant')
                  AND part.kind = 'text'
                  AND part.state = 'completed'
                  AND partState.present = 1
                ORDER BY conversation.id, message.sequence, part.sequence, vector.chunkIndex
                """, arguments: [profileID])
        }
    }

    @discardableResult
    func saveConversationVectorRecords(_ records: [ConversationVectorRecord]) throws -> Int {
        try database.write { db in
            var saved = 0
            for record in records {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO conversationSearch.conversationVectorRecord (
                        profileID, conversationID, partID, chunkIndex, startOffset, endOffset,
                        sourceRevision, contentHash, embedding
                    )
                    SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?
                    WHERE EXISTS (
                        SELECT 1
                        FROM main.conversation
                        JOIN main.message ON message.conversationID = conversation.id
                        JOIN main.messagePart AS part ON part.messageID = message.id
                        JOIN main.conversationSearchPartState AS partState ON partState.partID = part.id
                        WHERE conversation.id = ?
                          AND conversation.lifecycle = 'visible'
                          AND message.id = part.messageID
                          AND message.role IN ('user', 'assistant')
                          AND part.id = ?
                          AND part.kind = 'text'
                          AND part.state = 'completed'
                          AND partState.present = 1
                          AND partState.revision = ?
                    )
                    """, arguments: [
                        record.profileID,
                        record.conversationID,
                        record.partID,
                        record.chunkIndex,
                        record.startOffset,
                        record.endOffset,
                        record.sourceRevision,
                        record.contentHash,
                        record.embeddingData,
                        record.conversationID,
                        record.partID,
                        record.sourceRevision,
                    ])
                saved += db.changesCount
            }
            return saved
        }
    }

    func clearConversationVectorRecords() throws -> Int {
        try database.write { db in
            try db.execute(sql: "DELETE FROM conversationSearch.conversationVectorRecord")
            return db.changesCount
        }
    }
}

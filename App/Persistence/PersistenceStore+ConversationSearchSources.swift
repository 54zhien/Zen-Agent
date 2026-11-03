import Foundation
import GRDB

extension PersistenceStore {
    func conversationSearchSources() throws -> [ConversationSearchSource] {
        try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT conversation.id AS conversationID,
                       part.id AS partID,
                       partState.revision AS sourceRevision,
                       json_extract(part.payload, '$.text') AS text
                FROM main.conversation
                JOIN main.message ON message.conversationID = conversation.id
                JOIN main.messagePart AS part ON part.messageID = message.id
                JOIN main.conversationSearchPartState AS partState ON partState.partID = part.id
                WHERE conversation.lifecycle = 'visible'
                  AND message.role IN ('user', 'assistant')
                  AND part.kind = 'text'
                  AND part.state = 'completed'
                  AND partState.present = 1
                  AND CASE WHEN json_valid(part.payload)
                      THEN json_type(part.payload, '$.text') = 'text'
                      ELSE 0 END
                ORDER BY conversation.id, message.sequence, part.sequence, part.id
                """).map { row in
                    ConversationSearchSource(
                        conversationID: row["conversationID"],
                        partID: row["partID"],
                        sourceRevision: row["sourceRevision"],
                        text: row["text"]
                    )
                }
        }
    }
}

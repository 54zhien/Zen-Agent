import Foundation
import GRDB

extension PersistenceStore {
    func quoteReferences(forMessageID messageID: String) throws -> [MessageQuoteReferenceRecord] {
        try database.read { db in
            try MessageQuoteReferenceRecord
                .filter(Column("messageID") == messageID)
                .order(Column("sequence").asc)
                .fetchAll(db)
        }
    }

    /// A saved snapshot remains readable when its source has been deleted. This query
    /// only answers whether the original completed text Part can still be opened.
    func quoteSourceIsAvailable(_ reference: MessageQuoteReferenceRecord) throws -> Bool {
        try database.read { db in
            guard let message = try MessageRecord.fetchOne(db, key: reference.sourceMessageID),
                  message.conversationID == reference.sourceConversationID,
                  let part = try MessagePartRecord.fetchOne(db, key: reference.sourcePartID)
            else { return false }
            return part.messageID == message.id
                && part.kind == .text
                && part.state == .completed
        }
    }
}

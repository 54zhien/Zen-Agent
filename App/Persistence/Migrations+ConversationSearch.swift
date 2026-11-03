import GRDB

extension Migrations {
    static func registerV33(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v33_conversation_full_text_search") { db in
            ConversationSearchText.registerSQLiteFunction(in: db)
            try db.execute(sql: """
                CREATE VIRTUAL TABLE conversationSearchIndex USING fts4(
                    conversationID,
                    partID,
                    conversationKey,
                    partKey,
                    text,
                    notindexed=conversationID,
                    notindexed=partID,
                    tokenize=unicode61
                );

                INSERT INTO conversationSearchIndex(conversationID, partID, conversationKey, partKey, text)
                SELECT m.conversationID, p.id,
                       'c' || lower(hex(m.conversationID)),
                       'p' || lower(hex(p.id)),
                       zen_conversation_search_text(json_extract(p.payload, '$.text'))
                FROM messagePart p
                JOIN message m ON m.id = p.messageID
                WHERE p.kind IN ('text', 'reasoning')
                  AND m.role IN ('user', 'assistant')
                  AND CASE WHEN json_valid(p.payload)
                      THEN json_type(p.payload, '$.text') = 'text'
                      ELSE 0 END
                ORDER BY m.conversationID, m.sequence, p.sequence, p.id;

                CREATE TRIGGER conversationSearchIndex_part_insert
                AFTER INSERT ON messagePart
                WHEN NEW.kind IN ('text', 'reasoning')
                  AND EXISTS (
                      SELECT 1 FROM message m
                      WHERE m.id = NEW.messageID AND m.role IN ('user', 'assistant')
                  )
                  AND CASE WHEN json_valid(NEW.payload)
                      THEN json_type(NEW.payload, '$.text') = 'text'
                      ELSE 0 END
                BEGIN
                    INSERT INTO conversationSearchIndex(conversationID, partID, conversationKey, partKey, text)
                    SELECT m.conversationID, NEW.id,
                           'c' || lower(hex(m.conversationID)),
                           'p' || lower(hex(NEW.id)),
                           zen_conversation_search_text(json_extract(NEW.payload, '$.text'))
                    FROM message m WHERE m.id = NEW.messageID;
                END;

                CREATE TRIGGER conversationSearchIndex_part_update
                AFTER UPDATE OF payload ON messagePart
                BEGIN
                    DELETE FROM conversationSearchIndex
                    WHERE conversationSearchIndex MATCH 'partKey:p' || lower(hex(OLD.id));
                    INSERT INTO conversationSearchIndex(conversationID, partID, conversationKey, partKey, text)
                    SELECT m.conversationID, NEW.id,
                           'c' || lower(hex(m.conversationID)),
                           'p' || lower(hex(NEW.id)),
                           zen_conversation_search_text(json_extract(NEW.payload, '$.text'))
                    FROM message m
                    WHERE m.id = NEW.messageID
                      AND m.role IN ('user', 'assistant')
                      AND NEW.kind IN ('text', 'reasoning')
                      AND CASE WHEN json_valid(NEW.payload)
                          THEN json_type(NEW.payload, '$.text') = 'text'
                          ELSE 0 END;
                END;

                CREATE TRIGGER conversationSearchIndex_part_delete
                AFTER DELETE ON messagePart
                BEGIN
                    DELETE FROM conversationSearchIndex
                    WHERE conversationSearchIndex MATCH 'partKey:p' || lower(hex(OLD.id));
                END;

                """)
        }
    }
}

import GRDB

enum SearchIndexDatabase {
    static let schema = "conversationSearch"

    static func attach(path: String, to db: Database) throws {
        try db.execute(sql: "ATTACH DATABASE ? AS \(schema)", arguments: [path])
    }

    static func installSchema(in db: Database) throws {
        try db.execute(sql: """
            CREATE VIRTUAL TABLE IF NOT EXISTS \(schema).conversationSearchIndex USING fts4(
                conversationID,
                partID,
                conversationKey,
                partKey,
                text,
                notindexed=conversationID,
                notindexed=partID,
                tokenize=unicode61
            );

            CREATE TABLE IF NOT EXISTS \(schema).conversationSearchIndexMetadata (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                appliedRevision INTEGER NOT NULL
            );
            INSERT OR IGNORE INTO \(schema).conversationSearchIndexMetadata(id, appliedRevision)
            VALUES (1, 0);

            CREATE TABLE IF NOT EXISTS \(schema).conversationVectorRecord (
                profileID TEXT NOT NULL,
                conversationID TEXT NOT NULL,
                partID TEXT NOT NULL,
                chunkIndex INTEGER NOT NULL,
                startOffset INTEGER NOT NULL,
                endOffset INTEGER NOT NULL,
                sourceRevision INTEGER NOT NULL,
                contentHash TEXT NOT NULL,
                embedding BLOB NOT NULL,
                PRIMARY KEY (profileID, partID, chunkIndex)
            );
            CREATE INDEX IF NOT EXISTS \(schema).conversationVectorRecord_by_profile
                ON conversationVectorRecord(profileID, conversationID);
            """)
    }

    static func installMutationTriggers(in db: Database) throws {
        try db.execute(sql: """
            DROP TRIGGER IF EXISTS temp.conversationSearchIndex_stage11_part_insert;
            DROP TRIGGER IF EXISTS temp.conversationSearchIndex_stage11_part_update;
            DROP TRIGGER IF EXISTS temp.conversationSearchIndex_stage11_part_delete;
            DROP TRIGGER IF EXISTS temp.conversationSearchIndex_stage11_conversation_update;
            DROP TRIGGER IF EXISTS temp.conversationSearchIndex_stage11_message_update;

            CREATE TEMP TRIGGER conversationSearchIndex_stage11_part_insert
            AFTER INSERT ON main.messagePart
            BEGIN
                INSERT INTO conversationSearchPartState(partID, revision, present)
                VALUES (NEW.id, 1, 1)
                ON CONFLICT(partID) DO UPDATE SET revision = revision + 1, present = 1;

                UPDATE conversationSearchIndexState SET revision = revision + 1 WHERE id = 1;

                INSERT INTO conversationSearchIndex(conversationID, partID, conversationKey, partKey, text)
                SELECT conversation.id, NEW.id,
                       'c' || lower(hex(conversation.id)),
                       'p' || lower(hex(NEW.id)),
                       zen_conversation_search_text(json_extract(NEW.payload, '$.text'))
                FROM main.message
                JOIN main.conversation ON conversation.id = message.conversationID
                WHERE message.id = NEW.messageID
                  AND conversation.lifecycle = 'visible'
                  AND message.role IN ('user', 'assistant')
                  AND NEW.kind IN ('text', 'reasoning')
                  AND NEW.state = 'completed'
                  AND CASE WHEN json_valid(NEW.payload)
                      THEN json_type(NEW.payload, '$.text') = 'text'
                      ELSE 0 END;

                UPDATE conversationSearchIndexMetadata
                SET appliedRevision = (SELECT revision FROM conversationSearchIndexState WHERE id = 1)
                WHERE id = 1;
            END;

            CREATE TEMP TRIGGER conversationSearchIndex_stage11_part_update
            AFTER UPDATE OF payload, state, kind, messageID ON main.messagePart
            BEGIN
                DELETE FROM conversationSearchIndex
                WHERE conversationSearchIndex MATCH 'partKey:p' || lower(hex(OLD.id));
                DELETE FROM conversationVectorRecord WHERE partID = OLD.id;

                INSERT INTO conversationSearchPartState(partID, revision, present)
                VALUES (NEW.id, 1, 1)
                ON CONFLICT(partID) DO UPDATE SET revision = revision + 1, present = 1;

                UPDATE conversationSearchIndexState SET revision = revision + 1 WHERE id = 1;

                INSERT INTO conversationSearchIndex(conversationID, partID, conversationKey, partKey, text)
                SELECT conversation.id, NEW.id,
                       'c' || lower(hex(conversation.id)),
                       'p' || lower(hex(NEW.id)),
                       zen_conversation_search_text(json_extract(NEW.payload, '$.text'))
                FROM main.message
                JOIN main.conversation ON conversation.id = message.conversationID
                WHERE message.id = NEW.messageID
                  AND conversation.lifecycle = 'visible'
                  AND message.role IN ('user', 'assistant')
                  AND NEW.kind IN ('text', 'reasoning')
                  AND NEW.state = 'completed'
                  AND CASE WHEN json_valid(NEW.payload)
                      THEN json_type(NEW.payload, '$.text') = 'text'
                      ELSE 0 END;

                UPDATE conversationSearchIndexMetadata
                SET appliedRevision = (SELECT revision FROM conversationSearchIndexState WHERE id = 1)
                WHERE id = 1;
            END;

            CREATE TEMP TRIGGER conversationSearchIndex_stage11_part_delete
            AFTER DELETE ON main.messagePart
            BEGIN
                DELETE FROM conversationSearchIndex
                WHERE conversationSearchIndex MATCH 'partKey:p' || lower(hex(OLD.id));
                DELETE FROM conversationVectorRecord WHERE partID = OLD.id;

                INSERT INTO conversationSearchPartState(partID, revision, present)
                VALUES (OLD.id, 1, 0)
                ON CONFLICT(partID) DO UPDATE SET revision = revision + 1, present = 0;

                UPDATE conversationSearchIndexState SET revision = revision + 1 WHERE id = 1;

                UPDATE conversationSearchIndexMetadata
                SET appliedRevision = (SELECT revision FROM conversationSearchIndexState WHERE id = 1)
                WHERE id = 1;
            END;

            CREATE TEMP TRIGGER conversationSearchIndex_stage11_conversation_update
            AFTER UPDATE OF lifecycle ON main.conversation
            WHEN OLD.lifecycle != NEW.lifecycle
            BEGIN
                UPDATE conversationSearchPartState
                SET revision = revision + 1
                WHERE partID IN (
                    SELECT part.id FROM main.messagePart AS part
                    JOIN main.message ON message.id = part.messageID
                    WHERE message.conversationID = NEW.id
                );

                UPDATE conversationSearchIndexState SET revision = revision + 1 WHERE id = 1;

                DELETE FROM conversationSearchIndex
                WHERE conversationSearchIndex MATCH 'conversationKey:c' || lower(hex(NEW.id));
                DELETE FROM conversationVectorRecord WHERE conversationID = NEW.id;

                INSERT INTO conversationSearchIndex(conversationID, partID, conversationKey, partKey, text)
                SELECT conversation.id, part.id,
                       'c' || lower(hex(conversation.id)),
                       'p' || lower(hex(part.id)),
                       zen_conversation_search_text(json_extract(part.payload, '$.text'))
                FROM main.conversation
                JOIN main.message ON message.conversationID = conversation.id
                JOIN main.messagePart AS part ON part.messageID = message.id
                WHERE conversation.id = NEW.id
                  AND conversation.lifecycle = 'visible'
                  AND message.role IN ('user', 'assistant')
                  AND part.kind IN ('text', 'reasoning')
                  AND part.state = 'completed'
                  AND CASE WHEN json_valid(part.payload)
                      THEN json_type(part.payload, '$.text') = 'text'
                      ELSE 0 END
                ORDER BY message.sequence, part.sequence, part.id;

                UPDATE conversationSearchIndexMetadata
                SET appliedRevision = (SELECT revision FROM conversationSearchIndexState WHERE id = 1)
                WHERE id = 1;
            END;

            CREATE TEMP TRIGGER conversationSearchIndex_stage11_message_update
            AFTER UPDATE OF role, conversationID ON main.message
            WHEN OLD.role != NEW.role OR OLD.conversationID != NEW.conversationID
            BEGIN
                UPDATE conversationSearchPartState
                SET revision = revision + 1
                WHERE partID IN (SELECT part.id FROM main.messagePart AS part WHERE part.messageID = NEW.id);

                UPDATE conversationSearchIndexState SET revision = revision + 1 WHERE id = 1;

                DELETE FROM conversationSearchIndex
                WHERE conversationSearchIndex MATCH 'conversationKey:c' || lower(hex(OLD.conversationID));
                DELETE FROM conversationSearchIndex
                WHERE conversationSearchIndex MATCH 'conversationKey:c' || lower(hex(NEW.conversationID));
                DELETE FROM conversationVectorRecord
                WHERE partID IN (SELECT part.id FROM main.messagePart AS part WHERE part.messageID = NEW.id);

                INSERT INTO conversationSearchIndex(conversationID, partID, conversationKey, partKey, text)
                SELECT conversation.id, part.id,
                       'c' || lower(hex(conversation.id)),
                       'p' || lower(hex(part.id)),
                       zen_conversation_search_text(json_extract(part.payload, '$.text'))
                FROM main.conversation
                JOIN main.message ON message.conversationID = conversation.id
                JOIN main.messagePart AS part ON part.messageID = message.id
                WHERE conversation.id IN (OLD.conversationID, NEW.conversationID)
                  AND conversation.lifecycle = 'visible'
                  AND message.role IN ('user', 'assistant')
                  AND part.kind IN ('text', 'reasoning')
                  AND part.state = 'completed'
                  AND CASE WHEN json_valid(part.payload)
                      THEN json_type(part.payload, '$.text') = 'text'
                      ELSE 0 END
                ORDER BY conversation.id, message.sequence, part.sequence, part.id;

                UPDATE conversationSearchIndexMetadata
                SET appliedRevision = (SELECT revision FROM conversationSearchIndexState WHERE id = 1)
                WHERE id = 1;
            END;
            """)
    }

    static func reconcileFullTextIndex(in db: Database) throws {
        try db.execute(sql: """
            DELETE FROM conversationSearch.conversationVectorRecord
            WHERE NOT EXISTS (
                SELECT 1
                FROM main.conversation
                JOIN main.message ON message.conversationID = conversation.id
                JOIN main.messagePart AS part ON part.messageID = message.id
                JOIN main.conversationSearchPartState AS partState ON partState.partID = part.id
                WHERE conversation.id = conversationVectorRecord.conversationID
                  AND part.id = conversationVectorRecord.partID
                  AND partState.revision = conversationVectorRecord.sourceRevision
                  AND partState.present = 1
                  AND conversation.lifecycle = 'visible'
                  AND message.role IN ('user', 'assistant')
                  AND part.kind = 'text'
                  AND part.state = 'completed'
            )
            """)

        let sourceRevision = try Int64.fetchOne(db, sql: """
            SELECT revision FROM main.conversationSearchIndexState WHERE id = 1
            """) ?? 0
        let appliedRevision = try Int64.fetchOne(db, sql: """
            SELECT appliedRevision FROM conversationSearch.conversationSearchIndexMetadata WHERE id = 1
            """) ?? -1
        guard sourceRevision != appliedRevision else { return }

        try db.execute(sql: """
            DELETE FROM conversationSearch.conversationSearchIndex;
            INSERT INTO conversationSearch.conversationSearchIndex(conversationID, partID, conversationKey, partKey, text)
            SELECT conversation.id, part.id,
                   'c' || lower(hex(conversation.id)),
                   'p' || lower(hex(part.id)),
                   zen_conversation_search_text(json_extract(part.payload, '$.text'))
            FROM main.conversation
            JOIN main.message ON message.conversationID = conversation.id
            JOIN main.messagePart AS part ON part.messageID = message.id
            WHERE conversation.lifecycle = 'visible'
              AND message.role IN ('user', 'assistant')
              AND part.kind IN ('text', 'reasoning')
              AND part.state = 'completed'
              AND CASE WHEN json_valid(part.payload)
                  THEN json_type(part.payload, '$.text') = 'text'
                  ELSE 0 END
            ORDER BY conversation.id, message.sequence, part.sequence, part.id;

            UPDATE conversationSearch.conversationSearchIndexMetadata
            SET appliedRevision = ? WHERE id = 1;
            """, arguments: [sourceRevision])
    }
}

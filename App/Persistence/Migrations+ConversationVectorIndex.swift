import GRDB

extension Migrations {
    static func registerV34(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v34_derived_conversation_search_index") { db in
            try db.execute(sql: """
                DROP TRIGGER IF EXISTS conversationSearchIndex_part_insert;
                DROP TRIGGER IF EXISTS conversationSearchIndex_part_update;
                DROP TRIGGER IF EXISTS conversationSearchIndex_part_delete;
                DROP TABLE IF EXISTS conversationSearchIndex;

                CREATE TABLE conversationSearchIndexState (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    revision INTEGER NOT NULL
                );
                -- The separate derived database starts at revision 0. Revision 1
                -- makes its first open rebuild even when this source has no rows.
                INSERT INTO conversationSearchIndexState(id, revision) VALUES (1, 1);

                CREATE TABLE conversationSearchPartState (
                    partID TEXT PRIMARY KEY,
                    revision INTEGER NOT NULL,
                    present INTEGER NOT NULL
                );
                INSERT INTO conversationSearchPartState(partID, revision, present)
                SELECT id, 1, 1 FROM messagePart;
                """)
        }
    }
}

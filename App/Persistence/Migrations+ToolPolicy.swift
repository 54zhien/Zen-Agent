import GRDB

extension Migrations {
    static func registerV14(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v14_tool_policy_and_scoped_grants") { db in
            try db.execute(sql: """
                CREATE TABLE toolGlobalPolicy (
                    toolID TEXT COLLATE BINARY NOT NULL,
                    actionID TEXT COLLATE BINARY NOT NULL,
                    descriptorRevision TEXT NOT NULL,
                    mode TEXT NOT NULL CHECK (mode IN ('alwaysAllow','askEveryTime','deny')),
                    revocationEpoch INTEGER NOT NULL CHECK (typeof(revocationEpoch) = 'integer' AND revocationEpoch >= 0),
                    PRIMARY KEY (toolID, actionID)
                )
                """)
            try db.execute(sql: """
                CREATE TABLE toolScopedGrant (
                    id TEXT COLLATE BINARY PRIMARY KEY NOT NULL,
                    subjectKind TEXT NOT NULL CHECK (subjectKind IN ('parentConversation','run')),
                    subjectID TEXT COLLATE BINARY NOT NULL,
                    toolID TEXT COLLATE BINARY NOT NULL,
                    actionID TEXT COLLATE BINARY NOT NULL,
                    descriptorRevision TEXT NOT NULL,
                    resource TEXT NOT NULL,
                    destination TEXT NOT NULL,
                    kind TEXT NOT NULL CHECK (kind IN ('once','conversation')),
                    validity TEXT NOT NULL CHECK (validity IN ('active','revoked','consumed')),
                    revocationEpoch INTEGER NOT NULL CHECK (typeof(revocationEpoch) = 'integer' AND revocationEpoch >= 0),
                    issuedToolCallID TEXT NOT NULL,
                    issuedRunID TEXT NOT NULL,
                    issuedIntentBinding TEXT NOT NULL,
                    originConversationID TEXT NOT NULL
                )
                """)
            try db.create(index: "toolGrant_by_subject", on: "toolScopedGrant", columns: ["subjectKind", "subjectID"])
            try db.create(index: "toolGrant_by_action", on: "toolScopedGrant", columns: ["toolID", "actionID"])
            try db.create(index: "toolGrant_by_call", on: "toolScopedGrant", columns: ["issuedToolCallID"])
            try db.create(index: "toolGrant_by_run", on: "toolScopedGrant", columns: ["issuedRunID"])
            try db.create(index: "toolGrant_by_conversation", on: "toolScopedGrant", columns: ["originConversationID"])
            let terminalCalls = ToolCallState.allCases.filter { $0.isTerminal || $0 == .indeterminate }
                .map { "'\($0.rawValue)'" }.joined(separator: ",")
            let terminalRuns = RunState.allCases.filter(\.isTerminal).map { "'\($0.rawValue)'" }.joined(separator: ",")
            // These effects share the original owner's transaction, including
            // recovery/cancellation paths that do not pass through approval UI.
            try db.execute(sql: """
                CREATE TRIGGER toolGrant_consume_call
                AFTER UPDATE OF state ON toolCall WHEN NEW.state IN (\(terminalCalls))
                BEGIN
                    UPDATE toolScopedGrant SET validity = 'consumed'
                    WHERE issuedToolCallID = NEW.id AND kind = 'once' AND validity = 'active';
                END;
                """)
            try db.execute(sql: """
                CREATE TRIGGER toolGrant_consume_deleted_call AFTER DELETE ON toolCall
                BEGIN
                    UPDATE toolScopedGrant SET validity = 'consumed'
                    WHERE issuedToolCallID = OLD.id AND kind = 'once' AND validity = 'active';
                END;
                """)
            try db.execute(sql: """
                CREATE TRIGGER toolGrant_end_run
                AFTER UPDATE OF state ON agentRun WHEN NEW.state IN (\(terminalRuns))
                BEGIN
                    UPDATE toolScopedGrant SET validity = CASE WHEN kind = 'once' THEN 'consumed' ELSE 'revoked' END
                    WHERE validity = 'active' AND ((subjectKind = 'run' AND subjectID = NEW.id)
                        OR (kind = 'once' AND issuedRunID = NEW.id));
                END;
                """)
            try db.execute(sql: """
                CREATE TRIGGER toolGrant_delete_run AFTER DELETE ON agentRun
                BEGIN
                    UPDATE toolScopedGrant SET validity = CASE WHEN kind = 'once' THEN 'consumed' ELSE 'revoked' END
                    WHERE validity = 'active' AND ((subjectKind = 'run' AND subjectID = OLD.id)
                        OR (kind = 'once' AND issuedRunID = OLD.id));
                END;
                """)
            // No FK cascade on issuance history: a conversation grant outlives
            // its originating call/run. Ending the actual subject revokes it;
            // bringing a pending-deletion Conversation back cannot resurrect it.
            try db.execute(sql: """
                CREATE TRIGGER toolGrant_hide_conversation
                AFTER UPDATE OF lifecycle ON conversation WHEN NEW.lifecycle != 'visible'
                BEGIN
                    UPDATE toolScopedGrant SET validity = 'revoked' WHERE validity = 'active'
                        AND (originConversationID = NEW.id OR (subjectKind = 'parentConversation' AND subjectID = NEW.id));
                END;
                """)
            try db.execute(sql: """
                CREATE TRIGGER toolGrant_delete_conversation AFTER DELETE ON conversation
                BEGIN
                    UPDATE toolScopedGrant SET validity = 'revoked' WHERE validity = 'active'
                        AND (originConversationID = OLD.id OR (subjectKind = 'parentConversation' AND subjectID = OLD.id));
                END;
                """)
        }
    }
}

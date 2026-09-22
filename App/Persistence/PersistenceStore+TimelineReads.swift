import Foundation
import GRDB

/// Two reads the timeline needs and the store did not yet have.
///
/// Both are read-only: no business state is added here, and no existing invariant is
/// restated. They exist because the reads that were already present answer different
/// questions — `activeParentRuns(inConversation:)` answers "which runs are live right
/// now" and cannot serve a history read, and `run(id:)` needs the id before it can be
/// asked anything.
extension PersistenceStore {

    /// Every run in a conversation, oldest first. Stable tie-break on `id` so two runs
    /// created in the same instant still have one defined order — the timeline is ordered
    /// by this, and an unstable order would make the same conversation render differently
    /// between launches.
    ///
    /// `activeParentRuns(inConversation:)` answers a different question (which runs are live
    /// right now) and cannot serve a history read.
    func runs(inConversation id: String) throws -> [AgentRunRecord] {
        try database.read { db in
            try AgentRunRecord
                .filter(Column("conversationID") == id)
                .order(Column("createdAt").asc, Column("id").asc)
                .fetchAll(db)
        }
    }

    /// The results for a specific set of tool calls. Used by the timeline, which already has
    /// the call ids from the message parts and must not fetch the whole run's history again.
    func toolResults(forToolCallIDs ids: [String]) throws -> [ToolResultRecord] {
        guard !ids.isEmpty else { return [] }
        return try database.read { db in
            try ToolResultRecord
                .filter(ids.contains(Column("toolCallID")))
                .fetchAll(db)
        }
    }
}

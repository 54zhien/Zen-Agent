import Foundation
import GRDB

/// Per-request identity, and the check that discards stale streaming events.
///
/// **Not an Agent Runtime.** There is no loop, no state machine and no retry policy
/// here. What is here is the storage side of one question: when an event arrives
/// claiming to belong to a particular provider request, is that request still the one
/// we are listening to?
///
/// The rule that makes it answerable is that **a replay is a new attempt, never a
/// continuation of the old one.** A stopped run's late delta and a live one are
/// indistinguishable by content, so identity is the only thing that separates them.
extension PersistenceStore {

    /// Records a provider request for a step.
    ///
    /// `attempt` increments per real request, including replays. The composite primary
    /// key rejects recording the same attempt twice, so a double-recorded request
    /// fails loudly instead of quietly becoming two attempts — which would make the
    /// identity check below answer the wrong question.
    func recordStep(_ step: AgentStepRecord) throws {
        try database.write { db in
            try step.insert(db)
        }
    }

    func steps(inRun runID: String) throws -> [AgentStepRecord] {
        try database.read { db in
            try AgentStepRecord
                .filter(Column("runID") == runID)
                .order(Column("sequence"), Column("attempt"))
                .fetchAll(db)
        }
    }

    /// The attempt currently being listened to for a step, if any.
    func currentAttempt(ofStep stepID: String) throws -> AgentStepRecord? {
        try database.read { db in
            try AgentStepRecord
                .filter(Column("stepID") == stepID)
                .order(Column("attempt").desc)
                .fetchOne(db)
        }
    }

    /// Whether an arriving event belongs to the attempt we are still listening to.
    ///
    /// This is the whole point of recording attempts. A provider stream that was
    /// stopped, or a run that recovered onto a new attempt, keeps delivering events for
    /// a while — and those events are indistinguishable from live ones except by the
    /// identity they carry.
    func accepts(_ identity: AttemptIdentity) throws -> Bool {
        try currentAttempt(ofStep: identity.stepID)?.attempt == identity.attempt
    }
}

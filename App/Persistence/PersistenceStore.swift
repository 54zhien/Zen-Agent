import Foundation
import GRDB

/// Domain-level failures. Callers get these instead of GRDB errors, so the storage
/// engine's vocabulary never reaches the Runtime or the UI.
enum PersistenceError: Error, Equatable {
    /// The conversation already holds an active parent run.
    case conversationAlreadyHasActiveRun(conversationID: String)

    /// Some other constraint rejected the write — a duplicate id, most likely a
    /// replayed send.
    ///
    /// Kept distinct from the case above on purpose. Reporting every constraint
    /// failure as "the conversation is occupied" would send someone hunting for a
    /// concurrency bug when the real cause is a message id that was already written.
    case constraintViolation

    /// A caller asked for a state change the lifecycle does not allow — finishing a run
    /// with a non-terminal state, or undoing a deletion that was already finalised.
    case invalidTransition(String)

    /// The named conversation does not exist.
    case conversationNotFound(String)

    /// A referenced part does not exist. Not a constraint failure: the caller named
    /// something that was never written, or has already been erased.
    case partNotFound(String)

    /// The named Provider instance does not exist.
    case providerInstanceNotFound(ProviderInstanceID)

    /// A create was asked to make an instance whose id is already taken.
    ///
    /// Distinct from `constraintViolation` because it is not a bug in the caller's
    /// concurrency handling — it is a caller trying to write over an existing instance
    /// through the create path, which is the one thing that must not silently succeed.
    case providerInstanceAlreadyExists(ProviderInstanceID)

    /// The named run does not exist.
    case runNotFound(String)
}

/// Everything one send commit writes, as a single unit.
///
/// Grouped into one type rather than passed as loose arguments because these five
/// things are not independently meaningful: a message whose run is missing is a
/// conversation nothing can resume, and a run whose seed is missing cannot be
/// replayed. Making them one value makes "forgot to write the seed" a compile error
/// instead of a corrupted row.
struct SendCommit: Sendable {
    var conversation: ConversationRecord
    var message: MessageRecord
    var parts: [MessagePartRecord]
    var run: AgentRunRecord
}

/// The data layer's public surface.
///
/// Not a database-abstraction layer. ADR-0001 is settled, so nothing here exists to
/// keep GRDB swappable; the point is that **transaction rules live in one place** and
/// that callers cannot accidentally write half of a compound operation.
///
/// `Sendable` is declared rather than left to inference. It would be inferred anyway —
/// the only stored property is `ZenDatabase`, which is `Sendable` — but a conformance
/// to a `Sendable`-refining protocol declared in a different file (as
/// `CredentialMetadataRepository` is) must live here, next to the type. Being explicit
/// is also the honest description: this is meant to be shareable, not accidentally so.
struct PersistenceStore: Sendable {
    let database: ZenDatabase

    init(database: ZenDatabase) {
        self.database = database
    }

    // MARK: - Send commit

    /// Commits a user turn and creates its parent run **in one transaction**.
    ///
    /// The shape is the point. The alternative — exposing `insert(message:)` and
    /// `insert(run:)` separately — relies on every caller remembering to wrap them,
    /// and one caller that forgets produces a half-state that only shows up as a
    /// conversation that cannot be resumed. Here, all-or-nothing is the only thing
    /// the API can express.
    ///
    /// Throws `PersistenceError.conversationAlreadyHasActiveRun` when the conversation
    /// is already occupied.
    ///
    /// **Two layers, and the order matters.** The explicit check inside the transaction
    /// exists to produce a precise error message; it is *not* what guarantees the
    /// invariant. The partial unique index is. Removing the index because "the store
    /// already checks" would put the whole guarantee back on application discipline,
    /// which is the thing the spike ruled out.
    func commitUserTurnAndCreateParentRun(_ commit: SendCommit) throws {
        var claimed = commit.run
        // The active-slot rule is applied in exactly one place. Callers pass the run's
        // state and nothing else; forgetting to maintain a derived column is not a
        // mistake they can make.
        claimed.activeSlot = Self.activeSlot(for: claimed)
        let conversationID = claimed.conversationID

        // Bound to a `let` before the closure: the write block is `@Sendable`, so it
        // may not capture the mutable local above.
        let run = claimed

        do {
            try database.write { db in
                let occupied = try AgentRunRecord
                    .filter(Column("activeSlot") == conversationID)
                    .fetchCount(db) > 0
                guard !occupied else {
                    throw PersistenceError.conversationAlreadyHasActiveRun(conversationID: conversationID)
                }

                try commit.conversation.upsert(db)
                try commit.message.insert(db)
                for part in commit.parts {
                    try part.insert(db)
                }
                try run.insert(db)
            }
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
            // Anything reaching here is a *different* constraint. The occupied-slot
            // case was already caught by the check above, inside the same transaction —
            // and on a `DatabaseQueue` GRDB serialises writers, so no racing writer can
            // slip in between the check and the insert.
            //
            // Deliberately not inspecting the error text to work out which index fired.
            // Matching on a message string is exactly the "infer business meaning from
            // an error string" habit the notes forbid, and it would be paying for that
            // fragility to handle a path that is currently unreachable.
            //
            // When a `DatabasePool` arrives and concurrent writers become real, the
            // index starts doing load-bearing work and this mapping will need revisiting
            // — with a real discriminator, not a substring.
            throw PersistenceError.constraintViolation
        }
    }

    /// The conditional-uniqueness slot: the conversation id while a **parent** run is
    /// active, `nil` otherwise.
    ///
    /// Child runs are excluded deliberately. A child run is active too, but the
    /// per-conversation slot belongs to its parent — and if a child occupied the same
    /// slot, the first subagent would collide with the run that spawned it.
    ///
    /// "Active" is `!state.isTerminal`, defined once on `RunState`. So `suspended` and
    /// `stopping` hold the slot; only `completed`, `failed` and `cancelled` release it.
    static func activeSlot(for run: AgentRunRecord) -> String? {
        guard run.kind == .parent, run.state.isActive else { return nil }
        return run.conversationID
    }

    // MARK: - Run lifecycle

    /// Marks a run terminal and releases its active slot.
    ///
    /// The slot is released here rather than by the caller for the same reason it is
    /// claimed there: `stopping` and `suspended` must keep holding it, and a caller
    /// that clears the slot a moment too early would let a second parent run start
    /// while the first is still unwinding.
    ///
    /// Only terminal states release it — enforced below, not merely documented.
    func finishRun(id: String, state: RunState, endReason: EndReason, at now: Date = Date()) throws {
        guard state.isTerminal else {
            throw PersistenceError.invalidTransition(
                "finishRun requires a terminal state; got \(state.rawValue)"
            )
        }

        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE agentRun
                    SET state = ?, endReason = ?, activeSlot = NULL, updatedAt = ?
                    WHERE id = ?
                    """,
                arguments: [state.rawValue, endReason.rawValue, now, id]
            )
        }
    }

    // MARK: - Reads

    func conversation(id: String) throws -> ConversationRecord? {
        try database.read { db in
            try ConversationRecord.fetchOne(db, key: id)
        }
    }

    func messages(inConversation id: String) throws -> [MessageRecord] {
        try database.read { db in
            try MessageRecord
                .filter(Column("conversationID") == id)
                .order(Column("sequence"))
                .fetchAll(db)
        }
    }

    func run(id: String) throws -> AgentRunRecord? {
        try database.read { db in
            try AgentRunRecord.fetchOne(db, key: id)
        }
    }

    /// Runs still holding the conversation's active slot.
    ///
    /// Counted from the slot rather than from a state list, so the query cannot drift
    /// from the rule the index enforces.
    func activeParentRuns(inConversation id: String) throws -> [AgentRunRecord] {
        try database.read { db in
            try AgentRunRecord
                .filter(Column("activeSlot") == id)
                .fetchAll(db)
        }
    }
}

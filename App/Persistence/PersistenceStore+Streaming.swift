import Foundation
import GRDB

/// Persistence for a streaming assistant message.
///
/// **Not a transport.** There is no SSE parsing, no provider, no coalescing timer and
/// no UI here. What is here is the storage side of
/// one question: when a stream is interrupted, how much of it is on disk, and is the
/// terminal flush actually durable?
///
/// No new table. A streaming assistant message is a `messagePart` with state
/// `.streaming` whose payload grows, and the terminal flush is the state change to
/// `.completed`. The coalescing window belongs to the Runtime, which decides how often
/// to call `appendText`; the store's job is that whatever it is handed is durable.
extension PersistenceStore {

    /// The payload shape of a text part. Its own type rather than a bare string so the
    /// encoding is in one place.
    struct TextPartPayload: Codable, Sendable {
        var text: String
    }

    /// Adds a part. Normally part of a send commit; separate here for the streaming
    /// tests, which need an assistant part that is still arriving.
    func createPart(_ part: MessagePartRecord) throws {
        try database.write { db in
            try part.insert(db)
        }
    }

    /// Appends a coalesced chunk of streamed text.
    ///
    /// Read-modify-write inside one transaction. Safe here because GRDB serialises
    /// writers on a `DatabaseQueue` and the whole block is a single transaction —
    /// including it here rather than at the call site so a caller cannot split it.
    func appendText(toPart partID: String, delta: String, at now: Date = Date()) throws {
        try database.write { db in
            guard let part = try MessagePartRecord.fetchOne(db, key: partID) else {
                throw PersistenceError.partNotFound(partID)
            }

            var payload = try Self.decodeTextPayload(part.payload)
            payload.text += delta

            let encoded = try Self.encodeTextPayload(payload)
            try db.execute(
                sql: "UPDATE messagePart SET payload = ? WHERE id = ?",
                arguments: [encoded, partID]
            )
        }
    }

    /// The terminal flush: the part stops streaming and its content is final.
    ///
    /// Separate from the appends because it is the point the content becomes
    /// trustworthy. A run that ends while a part is still `.streaming` leaves a part
    /// nobody can tell is complete — which is why a run reaching a terminal state must
    /// close its parts.
    func finishPart(id: String, state: MessagePartState, at now: Date = Date()) throws {
        guard state != .streaming && state != .pending else {
            throw PersistenceError.invalidTransition(
                "finishPart requires a settled state; got \(state.rawValue)"
            )
        }
        let open = [
            MessagePartState.streaming.rawValue,
            MessagePartState.pending.rawValue,
        ]
        let questionMarks = databaseQuestionMarks(count: open.count)

        try database.write { db in
            try db.execute(
                sql: "UPDATE messagePart SET state = ? WHERE id = ? AND state IN (\(questionMarks))",
                arguments: StatementArguments([state.rawValue, id] + open)
            )
            if db.changesCount == 0 {
                try Self.refuseMissedStateUpdate(
                    db,
                    table: "messagePart",
                    id: id,
                    precondition: "an open state (streaming or pending)",
                    notFound: PersistenceError.partNotFound(id)
                )
            }
        }
    }

    func part(id: String) throws -> MessagePartRecord? {
        try database.read { db in
            try MessagePartRecord.fetchOne(db, key: id)
        }
    }

    func parts(ofMessage messageID: String) throws -> [MessagePartRecord] {
        try database.read { db in
            try MessagePartRecord
                .filter(Column("messageID") == messageID)
                .order(Column("sequence"))
                .fetchAll(db)
        }
    }

    func text(ofPart partID: String) throws -> String? {
        try part(id: partID).map { try Self.decodeTextPayload($0.payload).text }
    }

    // MARK: - Internals

    static func decodeTextPayload(_ raw: String) throws -> TextPartPayload {
        try JSONDecoder().decode(TextPartPayload.self, from: Data(raw.utf8))
    }

    static func encodeTextPayload(_ payload: TextPartPayload) throws -> String {
        String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
    }
}

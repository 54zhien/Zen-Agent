import Foundation
import GRDB

/// Storage for user-added Provider connections.
///
/// Holds configuration and a credential *reference*. The material is in the Keychain,
/// and `SecretValue` is not `Codable`, so this file could not store one if it tried.
extension PersistenceStore {

    func providerInstance(id: ProviderInstanceID) throws -> ProviderInstance? {
        try database.read { db in
            try ProviderInstanceRecord.fetchOne(db, key: id.rawValue).map(Self.providerInstance(from:))
        }
    }

    func providerInstances() throws -> [ProviderInstance] {
        try database.read { db in
            try ProviderInstanceRecord
                .order(Column("displayName"))
                .fetchAll(db)
                .map(Self.providerInstance(from:))
        }
    }

    /// Creates an instance. **Fails if the id is already taken.**
    ///
    /// There is deliberately no general-purpose save. A method that wrote whatever it
    /// was handed would be a path around the revision: a caller could change an
    /// endpoint, or the credential, and leave `configRevision` where it was, so every
    /// paused run would go on believing it still matched. This method is the only way
    /// a row comes into existence, and every change to one that exists goes through a
    /// named mutation below that bumps the revision itself.
    func createProviderInstance(_ instance: ProviderInstance, at now: Date = Date()) throws {
        try database.write { db in
            guard try ProviderInstanceRecord.fetchOne(db, key: instance.id.rawValue) == nil else {
                throw PersistenceError.providerInstanceAlreadyExists(instance.id)
            }
            try Self.newProviderInstanceRecord(from: instance, at: now).insert(db)
        }
    }

    /// The one path every **mutation of a row that already exists** takes.
    ///
    /// `deleteProviderInstance` is deliberately not routed through here. There is no
    /// read-modify-write to lose: a delete either removes the row or does nothing, and
    /// "the row I acted on is gone" is the outcome the caller asked for. Guarding it
    /// would mean a user who confirmed a deletion could be told their confirmation had
    /// gone stale, which is a worse answer than the deletion winning.
    ///
    /// **Read, decide and write happen inside a single transaction.** A `DatabaseQueue`
    /// serialises whole transactions, not individual statements: two calls that each
    /// open their own `write` are two transactions, and everything between them is a
    /// window. Two failures lived in that window.
    ///
    /// An instance could be deleted in it, and the follow-up write then threw GRDB's own
    /// `RecordError` at the caller — the storage engine's vocabulary in front of a
    /// domain problem. And a second editor could read the same row and write back the
    /// whole object it had read, silently discarding the first editor's change.
    ///
    /// The update is conditional on the revision the caller read, so a write built on a
    /// snapshot something else has moved past changes **zero rows** rather than
    /// clobbering the newer one, and the caller is told which of the two happened.
    ///
    /// Only the columns the mutation is allowed to touch are assigned, and the values
    /// come from the row read *in this transaction* rather than from anything the caller
    /// carried. The previous shape wrote the whole record back, which is what let a
    /// stale snapshot revert a column its editor never meant to change — `configRevision`
    /// among them, the one value a frozen run compares against.
    private func mutateProviderInstance(
        id: ProviderInstanceID,
        expectedEditRevision: ProviderInstanceEditRevision,
        at now: Date,
        _ mutation: InstanceMutation
    ) throws -> ProviderInstance {
        do {
            return try database.write { db in
                guard let current = try ProviderInstanceRecord.fetchOne(db, key: id.rawValue) else {
                    throw PersistenceError.providerInstanceNotFound(id)
                }
                guard current.editRevision == expectedEditRevision.rawValue else {
                    throw PersistenceError.providerInstanceEditConflict(
                        id: id,
                        expected: expectedEditRevision,
                        actual: ProviderInstanceEditRevision(rawValue: current.editRevision)
                    )
                }

                var assignments = try Self.assignments(for: mutation, on: current)
                let nextEditRevision = try expectedEditRevision.next()
                assignments.append(Column("editRevision").set(to: nextEditRevision.rawValue))
                assignments.append(Column("updatedAt").set(to: now))

                let updated = try ProviderInstanceRecord
                    .filter(Column("id") == id.rawValue)
                    .filter(Column("editRevision") == expectedEditRevision.rawValue)
                    .updateAll(db, assignments)

                // The check above and this statement are in the same transaction, so on
                // a `DatabaseQueue` this cannot be zero today. It is decided here anyway,
                // because it is the *statement* — not the check — that carries the
                // condition, and deciding it here is what keeps the guarantee if this
                // store ever grows a concurrent writer: that day changes nothing about
                // what a caller sees.
                guard updated == 1 else {
                    guard let after = try ProviderInstanceRecord.fetchOne(db, key: id.rawValue) else {
                        throw PersistenceError.providerInstanceNotFound(id)
                    }
                    throw PersistenceError.providerInstanceEditConflict(
                        id: id,
                        expected: expectedEditRevision,
                        actual: ProviderInstanceEditRevision(rawValue: after.editRevision)
                    )
                }

                guard let record = try ProviderInstanceRecord.fetchOne(db, key: id.rawValue) else {
                    throw PersistenceError.providerInstanceNotFound(id)
                }
                return Self.providerInstance(from: record)
            }
        } catch let error as PersistenceError {
            // Already this layer's vocabulary, and a better diagnosis than the
            // catch-all below could give.
            throw error
        } catch ConfigRevision.FormatError.notACounter(let rawValue) {
            throw PersistenceError.providerInstanceRevisionUnreadable(id: id, rawValue: rawValue)
        } catch ProviderInstanceEditRevision.FormatError.notACounter(let rawValue) {
            throw PersistenceError.providerInstanceRevisionUnreadable(id: id, rawValue: String(rawValue))
        } catch {
            // Nothing from the storage engine reaches a caller.
            throw PersistenceError.providerInstanceMutationFailed(id: id, reason: String(describing: error))
        }
    }

    /// What a mutation is allowed to change, as a value rather than a closure.
    ///
    /// A value because it has to cross into the write block, which is `@Sendable`.
    /// Naming the two mutations here is also what keeps "which columns may this change"
    /// a property of the enum, rather than something each caller assembles and can get
    /// wrong.
    private enum InstanceMutation: Sendable {
        case reconfigure(displayName: String, baseURL: URL?)
        case credential(CredentialReference?)
    }

    /// The columns `mutation` is allowed to change, read from the row in hand.
    ///
    /// `configRevision` is assigned only by `reconfigure`, and is advanced from the value
    /// the **row** holds rather than from anything the caller passed. An instance cannot
    /// be edited without the revision moving, and it cannot be moved to a value derived
    /// from a read that has since gone stale.
    private static func assignments(
        for mutation: InstanceMutation,
        on current: ProviderInstanceRecord
    ) throws -> [ColumnAssignment] {
        switch mutation {
        case .reconfigure(let displayName, let baseURL):
            let advanced = try ConfigRevision(rawValue: current.configRevision).next()
            return [
                Column("displayName").set(to: displayName),
                Column("baseURL").set(to: baseURL?.absoluteString),
                Column("configRevision").set(to: advanced.rawValue),
            ]
        case .credential(let reference):
            // `configRevision` deliberately stays put. See `attachCredential`.
            return [
                Column("credentialID").set(to: reference?.id),
                Column("credentialKind").set(to: reference?.kind.rawValue),
            ]
        }
    }

    /// Edits the configuration and bumps the revision in one step.
    ///
    /// The revision is bumped inside the same transaction as the write, not by the
    /// caller. That is what makes it impossible to change an instance without changing
    /// what a frozen run compares against: a caller that edited the display name and
    /// forgot the revision would leave every paused run still believing it matched.
    ///
    /// `expectedEditRevision` is the revision of the snapshot this edit was made from —
    /// `ProviderInstance.editRevision`, as read. An instance that has moved since that
    /// read gets `.providerInstanceEditConflict` rather than a lost update.
    ///
    /// `credentialReference` is left alone — attaching or detaching a credential is a
    /// separate act, and folding it in would mean an edit could silently drop one.
    @discardableResult
    func reconfigureProviderInstance(
        id: ProviderInstanceID,
        displayName: String,
        baseURL: URL?,
        expectedEditRevision: ProviderInstanceEditRevision,
        at now: Date = Date()
    ) throws -> ProviderInstance {
        try mutateProviderInstance(
            id: id,
            expectedEditRevision: expectedEditRevision,
            at: now,
            .reconfigure(displayName: displayName, baseURL: baseURL)
        )
    }

    /// Attaches a credential reference, or detaches it with `nil`.
    ///
    /// Detaching is how an instance becomes "unauthenticated but kept". The configuration
    /// stays; only the pointer to the secret goes.
    ///
    /// **Deliberately does not bump `configRevision`.** The credential is not part of
    /// "the configuration" — it is a second, orthogonal thing a run freezes, and it is
    /// frozen explicitly in the seed's `CredentialBindingSnapshot`. Bumping the revision
    /// here would make the credential's identity depend on a counter that exists to
    /// describe something else, and would invalidate runs for a change that the seed
    /// already detects on its own.
    ///
    /// It **does** bump `editRevision`. That is a different counter answering a different
    /// question — "is this still the row I read" rather than "does a frozen run still
    /// match" — and it is the whole reason the two are separate rather than one. Without
    /// it this mutation would be the one edit concurrent control could not see, and a
    /// credential attach carrying a stale snapshot would write back the endpoint and the
    /// `configRevision` it read.
    @discardableResult
    func attachCredential(
        _ reference: CredentialReference?,
        toInstance id: ProviderInstanceID,
        expectedEditRevision: ProviderInstanceEditRevision,
        at now: Date = Date()
    ) throws -> ProviderInstance {
        try mutateProviderInstance(
            id: id,
            expectedEditRevision: expectedEditRevision,
            at: now,
            .credential(reference)
        )
    }

    /// Removes the instance. Does **not** touch the credential.
    ///
    /// The caller is responsible for checking whether the credential is shared before
    /// deleting it — the notes require that check explicitly (`安全与权限.md:53`), and
    /// it needs knowledge of other references that this layer does not have.
    func deleteProviderInstance(id: ProviderInstanceID) throws {
        try database.write { db in
            try ProviderInstanceRecord.deleteOne(db, key: id.rawValue)
        }
    }

    // MARK: - Row mapping

    private static func providerInstance(from record: ProviderInstanceRecord) -> ProviderInstance {
        ProviderInstance(
            id: ProviderInstanceID(rawValue: record.id),
            providerID: ProviderID(rawValue: record.providerID),
            displayName: record.displayName,
            baseURL: record.baseURL.flatMap(URL.init(string:)),
            configRevision: ConfigRevision(rawValue: record.configRevision),
            editRevision: ProviderInstanceEditRevision(rawValue: record.editRevision),
            credentialReference: record.credentialID.map {
                CredentialReference(
                    id: $0,
                    kind: CredentialKind(rawValue: record.credentialKind ?? "") ?? .apiKey
                )
            }
        )
    }

    /// The row to insert for a **new** instance.
    ///
    /// `editRevision` is the schema's start, not the caller's. A `ProviderInstance` read
    /// from somewhere else carries the revision of the row it was read from, and writing
    /// that onto a fresh row would make the counter mean something different: an editor
    /// holding the old snapshot would find its revision "matching" a row it never read,
    /// which is the one thing the counter exists to prevent. It is derived here for the
    /// same reason `createdAt` is — a value the store owns is not something a caller
    /// should be able to supply.
    ///
    /// What this does not close: a snapshot taken at revision N, followed by a delete and
    /// then a re-create, is back at N and would be accepted. Telling those two rows apart
    /// needs an identity for the row itself rather than a counter — a counter's whole
    /// premise is that the row it counts is the row that was read. Deleting an instance
    /// and adding one are two acts the user asked for, and a fresh row genuinely is fresh.
    private static func newProviderInstanceRecord(from instance: ProviderInstance, at now: Date) -> ProviderInstanceRecord {
        ProviderInstanceRecord(
            id: instance.id.rawValue,
            providerID: instance.providerID.rawValue,
            displayName: instance.displayName,
            baseURL: instance.baseURL?.absoluteString,
            configRevision: instance.configRevision.rawValue,
            credentialID: instance.credentialReference?.id,
            credentialKind: instance.credentialReference?.kind.rawValue,
            editRevision: ProviderInstanceEditRevision.initial.rawValue,
            createdAt: now,
            updatedAt: now
        )
    }
}

/// The stored shape. `createdAt` is set on create and never rewritten — the mutations
/// assign named columns rather than writing a whole object back, so it is not something
/// they have to remember to preserve.
///
/// `editRevision` is `INTEGER` here while `configRevision` is text. See
/// `ProviderInstanceEditRevision`.
struct ProviderInstanceRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "providerInstance"

    var id: String
    var providerID: String
    var displayName: String
    var baseURL: String?
    var configRevision: String
    var credentialID: String?
    var credentialKind: String?
    var editRevision: Int
    var createdAt: Date
    var updatedAt: Date
}

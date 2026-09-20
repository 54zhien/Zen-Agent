import Foundation
import Testing

import GRDB

@testable import ZenAgent

/// Product invariant: **an edit lands against the instance as it is now, not as it was
/// when the editor read it.**
///
/// `configRevision` exists so a frozen run notices that what it was frozen against has
/// moved. On its own it does not stop two editors changing the same instance at once,
/// and `PersistenceStore+ProviderInstances.swift` claims of the mutation path that "it
/// has to be impossible to change an instance without changing what a frozen run
/// compares against".
///
/// That claim did not hold. The mutation read the instance in one transaction and wrote
/// it in another, and the write put back the **whole object** it had read, so:
///
/// 1. A second editor's write carried the values it read *before* the first editor's
///    write, reverting every column the first changed — `configRevision` among them,
///    which is the one value a frozen run compares.
/// 2. `attachCredential` went through the same write, so an operation that only meant to
///    move a credential pointer could revert a rename and an endpoint change it never
///    touched.
///
/// These pin both, plus the two ways the same read-then-write shape could fail on its
/// own: a stale edit against a row that is gone, and a revision the build cannot count.
@Suite("Provider instance edit concurrency")
struct ProviderInstanceEditConcurrencyTests {

    private static let instanceID = ProviderInstanceID(rawValue: "pi-1")
    private static let originalEndpoint = "https://api.deepseek.com"
    private static let editedEndpoint = "https://proxy.example.com"

    private func makeStore() throws -> PersistenceStore {
        PersistenceStore(database: try ZenDatabase.inMemory())
    }

    @discardableResult
    private func seedInstance(_ store: PersistenceStore) throws -> ProviderInstance {
        let instance = ProviderInstance(
            id: Self.instanceID,
            providerID: .deepSeek,
            displayName: "DeepSeek",
            baseURL: URL(string: Self.originalEndpoint),
            configRevision: .initial
        )
        try store.createProviderInstance(instance)
        return instance
    }

    /// Runs an edit the way an edit form does — submitting the configuration it read
    /// alongside the field the user actually touched — and hands back the failure
    /// instead of throwing, so the assertion can say what came out.
    private func reconfigure(
        _ store: PersistenceStore,
        displayName: String,
        baseURL: URL?,
        expectedEditRevision: ProviderInstanceEditRevision
    ) -> Error? {
        do {
            _ = try store.reconfigureProviderInstance(
                id: Self.instanceID,
                displayName: displayName,
                baseURL: baseURL,
                expectedEditRevision: expectedEditRevision
            )
            return nil
        } catch {
            return error
        }
    }

    // MARK: - A write built on a stale read is refused, not performed

    @Test("a rename built on a stale snapshot is refused, and the newer edit stands")
    func staleRenameIsRefused() throws {
        let store = try makeStore()
        try seedInstance(store)

        // Two editors open the same instance. Each holds the configuration it read,
        // which is what a form does.
        guard let editorA = try store.providerInstance(id: Self.instanceID),
              let editorB = try store.providerInstance(id: Self.instanceID) else {
            Issue.record("expected the seeded instance to read back")
            return
        }

        // A repoints the endpoint.
        let afterA = try store.reconfigureProviderInstance(
            id: Self.instanceID,
            displayName: editorA.displayName,
            baseURL: URL(string: Self.editedEndpoint),
            expectedEditRevision: editorA.editRevision
        )

        // B submits a rename, still carrying the snapshot it read before A's write.
        let failure = reconfigure(
            store,
            displayName: "DeepSeek (work)",
            baseURL: editorB.baseURL,
            expectedEditRevision: editorB.editRevision
        )

        #expect(
            failure as? ZenAgent.PersistenceError == .providerInstanceEditConflict(
                id: Self.instanceID,
                expected: editorB.editRevision,
                actual: afterA.editRevision
            ),
            """
            the stale write must be refused and named; got \(String(describing: failure)). \
            Before this change it succeeded, and because it wrote back the whole object it \
            had read, it reverted A's endpoint and put `configRevision` back to the value \
            A had already moved past.
            """
        )

        let after = try store.providerInstance(id: Self.instanceID)
        #expect(
            after?.baseURL?.absoluteString == Self.editedEndpoint,
            "A's endpoint edit must stand; got \(String(describing: after?.baseURL?.absoluteString))"
        )
        #expect(
            after?.displayName == editorA.displayName,
            "and B's refused rename must not have landed; got \(String(describing: after?.displayName))"
        )
    }

    @Test("a credential attach built on a stale snapshot is refused, and the newer edit stands")
    func staleAttachIsRefused() throws {
        let store = try makeStore()
        try seedInstance(store)

        guard let beforeRename = try store.providerInstance(id: Self.instanceID),
              let stale = try store.providerInstance(id: Self.instanceID) else {
            Issue.record("expected the seeded instance to read back")
            return
        }

        // Another editor renames and repoints the endpoint while the credential attach
        // is in flight, built from the snapshot above.
        let renamed = try store.reconfigureProviderInstance(
            id: Self.instanceID,
            displayName: "renamed",
            baseURL: URL(string: Self.editedEndpoint),
            expectedEditRevision: beforeRename.editRevision
        )

        var failure: Error?
        do {
            _ = try store.attachCredential(
                CredentialReference(id: "cred-2"),
                toInstance: Self.instanceID,
                expectedEditRevision: stale.editRevision
            )
        } catch {
            failure = error
        }

        #expect(
            failure as? ZenAgent.PersistenceError == .providerInstanceEditConflict(
                id: Self.instanceID,
                expected: stale.editRevision,
                actual: renamed.editRevision
            ),
            """
            the attach must be refused; got \(String(describing: failure)). It used to \
            succeed and write the whole object back, undoing the rename, the endpoint, \
            and the `configRevision` along with them.
            """
        )

        let after = try store.providerInstance(id: Self.instanceID)
        #expect(after?.credentialReference == nil, "the refused attach must not have landed")
        #expect(
            after?.baseURL?.absoluteString == Self.editedEndpoint,
            "and the rename must stand; got \(String(describing: after?.baseURL?.absoluteString))"
        )
        #expect(after?.configRevision == renamed.configRevision)
    }

    // MARK: - The counter that has to move for a credential attach

    @Test("attaching a credential moves the edit revision and leaves the config revision alone")
    func attachMovesOnlyTheEditRevision() throws {
        let store = try makeStore()
        try seedInstance(store)

        guard let before = try store.providerInstance(id: Self.instanceID) else {
            Issue.record("expected the seeded instance to read back")
            return
        }

        let after = try store.attachCredential(
            CredentialReference(id: "cred-2"),
            toInstance: Self.instanceID,
            expectedEditRevision: before.editRevision
        )

        #expect(after.credentialReference == CredentialReference(id: "cred-2"))
        #expect(
            after.configRevision == before.configRevision,
            """
            attaching a credential is not a configuration edit — a run frozen against \
            this instance must not be invalidated by it
            """
        )
        #expect(
            after.editRevision != before.editRevision,
            """
            but it *is* an edit to the row, so concurrent control has to be able to see \
            it. A single counter cannot both move here and stay put above, which is why \
            there are two.
            """
        )
    }

    // MARK: - The counter starts where the schema starts it

    @Test("creating an instance starts its counter at the schema's zero, not the caller's")
    func createStartsTheCounterAtZero() throws {
        let store = try makeStore()
        let original = try seedInstance(store)

        // An instance that has been edited, then deleted and re-created from that
        // snapshot — an undo, or simply adding it again.
        let edited = try store.reconfigureProviderInstance(
            id: Self.instanceID,
            displayName: "renamed",
            baseURL: nil,
            expectedEditRevision: original.editRevision
        )
        try store.deleteProviderInstance(id: Self.instanceID)
        try store.createProviderInstance(edited)

        let recreated = try store.providerInstance(id: Self.instanceID)
        #expect(
            recreated?.editRevision == .initial,
            """
            a new row must start where the schema starts one. Carrying the snapshot's \
            counter onto it would let an editor still holding that snapshot pass the \
            guard against a row it never read — the counter would be comparing a value \
            that no longer means "the row I read". Got \
            \(String(describing: recreated?.editRevision.rawValue)).
            """
        )
        #expect(recreated?.displayName == "renamed", "and the re-created row keeps what it was given")
    }

    // MARK: - The two ways the read-then-write shape failed on its own

    @Test("an edit revision at the end of its range is refused rather than trapping")
    func unbumpableEditRevisionIsRefused() throws {
        let store = try makeStore()
        try seedInstance(store)

        // The counter's ceiling, which a hand-edited or badly imported store can hold —
        // and which `rawValue + 1` does not throw on, it traps. A process killed by a
        // counter is not the typed refusal the rest of this path promises.
        try store.database.write { db in
            try db.execute(
                sql: "UPDATE providerInstance SET editRevision = ? WHERE id = ?",
                arguments: [Int.max, Self.instanceID.rawValue]
            )
        }

        guard let stale = try store.providerInstance(id: Self.instanceID) else {
            Issue.record("expected the instance to read back")
            return
        }
        #expect(stale.editRevision.rawValue == Int.max, "the fixture must actually plant the ceiling")

        let failure = reconfigure(
            store,
            displayName: "renamed",
            baseURL: nil,
            expectedEditRevision: stale.editRevision
        )

        #expect(
            failure as? ZenAgent.PersistenceError
                == .providerInstanceRevisionUnreadable(id: Self.instanceID, rawValue: String(Int.max)),
            "expected the typed refusal; got \(String(describing: failure))"
        )
    }

    @Test("a stale edit against a deleted instance is a typed failure")
    func staleEditAfterDeleteIsTyped() throws {
        let store = try makeStore()
        try seedInstance(store)

        guard let stale = try store.providerInstance(id: Self.instanceID) else {
            Issue.record("expected the seeded instance to read back")
            return
        }
        try store.deleteProviderInstance(id: Self.instanceID)

        let failure = reconfigure(
            store,
            displayName: "x",
            baseURL: nil,
            expectedEditRevision: stale.editRevision
        )

        #expect(
            failure as? ZenAgent.PersistenceError == .providerInstanceNotFound(Self.instanceID),
            """
            expected the store's own vocabulary; got \(String(describing: failure)). A \
            GRDB `RecordError` here is the storage engine talking to the caller about a \
            domain problem — which is what a delete landing between the read and the \
            write used to produce.
            """
        )
    }

    @Test("a revision that cannot be counted is refused rather than renumbered")
    func unbumpableRevisionIsRefused() throws {
        let store = try makeStore()
        try seedInstance(store)

        // A revision this build cannot parse. Nothing writes one — `ConfigRevision.next`
        // produces counters — but the column is text, and a store that has been through
        // a hand edit or a bad import can hold one.
        try store.database.write { db in
            try db.execute(
                sql: "UPDATE providerInstance SET configRevision = ? WHERE id = ?",
                arguments: ["config-r1", Self.instanceID.rawValue]
            )
        }

        guard let stale = try store.providerInstance(id: Self.instanceID) else {
            Issue.record("expected the instance to read back")
            return
        }

        let failure = reconfigure(
            store,
            displayName: "renamed",
            baseURL: nil,
            expectedEditRevision: stale.editRevision
        )

        #expect(
            failure as? ZenAgent.PersistenceError
                == .providerInstanceRevisionUnreadable(id: Self.instanceID, rawValue: "config-r1"),
            """
            expected a refusal; got \(String(describing: failure)). The old arithmetic, \
            `Int(rawValue) ?? 0`, turned this into \(ConfigRevision.initial.rawValue) — a \
            revision some run may already have been frozen against, so the edit landed \
            without moving the value that run compares.
            """
        )
        #expect(
            try store.providerInstance(id: Self.instanceID)?.configRevision.rawValue == "config-r1",
            "and the refused edit must not have renumbered anything"
        )
    }
}

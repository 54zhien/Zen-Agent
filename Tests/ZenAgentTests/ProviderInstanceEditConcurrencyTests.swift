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
/// Two things break that claim, and both come from one mechanism: the mutation **reads
/// the instance in one transaction and writes it in another**, and the write puts back
/// the **whole object** it read.
///
/// 1. A second editor's write carries the values it read *before* the first editor's
///    write, so it reverts every column the first editor changed — including
///    `configRevision`, which is restored to a revision a frozen run may already hold.
/// 2. `attachCredential` goes through the same write, so an operation that only meant to
///    move a credential pointer can revert a rename and an endpoint change it never
///    touched.
///
/// These pin the defect before it is fixed. The fix commit rewrites them onto the API
/// that refuses a stale write, where they pass.
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

    /// Runs a rename the way an edit form does: it submits the whole configuration it
    /// read, not just the field the user touched.
    @discardableResult
    private func rename(_ store: PersistenceStore, to displayName: String, endpoint: URL?) throws -> ProviderInstance {
        try store.reconfigureProviderInstance(
            id: Self.instanceID,
            displayName: displayName,
            baseURL: endpoint
        )
    }

    // MARK: - A write built on a stale read reverts what it never touched

    @Test("a rename built on a stale snapshot does not revert another editor's endpoint")
    func staleRenameDoesNotRevertAnEndpoint() throws {
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
        try rename(store, to: editorA.displayName, endpoint: URL(string: Self.editedEndpoint))

        // B submits a rename, still carrying the endpoint it read.
        try rename(store, to: "DeepSeek (work)", endpoint: editorB.baseURL)

        let after = try store.providerInstance(id: Self.instanceID)
        #expect(
            after?.baseURL?.absoluteString == Self.editedEndpoint,
            """
            A's endpoint edit did not survive B's rename. B read before A wrote, and the \
            write put the whole object back, so a field B's editor never touched was \
            reverted to the value B read. Endpoint is now \
            \(String(describing: after?.baseURL?.absoluteString)).
            """
        )
    }

    @Test("attaching a credential does not revert an edit made since it was read")
    func staleAttachDoesNotRevertAnEdit() throws {
        let store = try makeStore()
        try seedInstance(store)

        guard let stale = try store.providerInstance(id: Self.instanceID) else {
            Issue.record("expected the seeded instance to read back")
            return
        }

        // Another editor repoints the endpoint while the credential attach is in
        // flight, built from the snapshot above.
        let renamed = try rename(store, to: stale.displayName, endpoint: URL(string: Self.editedEndpoint))

        var failure: Error?
        do {
            _ = try store.attachCredential(CredentialReference(id: "cred-2"), toInstance: Self.instanceID)
        } catch {
            failure = error
        }

        let after = try store.providerInstance(id: Self.instanceID)
        #expect(
            after?.baseURL?.absoluteString == Self.editedEndpoint,
            """
            attaching a credential reverted an endpoint change. The attach read the \
            instance, then wrote the whole object back, so an edit made in between was \
            undone by an operation that only meant to move a credential pointer. \
            Endpoint is now \(String(describing: after?.baseURL?.absoluteString)); \
            failure was \(String(describing: failure)).
            """
        )
        #expect(
            after?.configRevision == renamed.configRevision,
            """
            and it put `configRevision` back to the value it read, so the instance now \
            reports a revision a run frozen against the *pre-attach* configuration may \
            still hold — while its endpoint is the one that edit installed. Expected \
            \(renamed.configRevision.rawValue), got \
            \(String(describing: after?.configRevision.rawValue)).
            """
        )
    }

    // MARK: - A revision that cannot be counted

    @Test("a revision that cannot be counted is not silently renumbered")
    func unbumpableRevisionIsNotRenumbered() throws {
        let store = try makeStore()
        try seedInstance(store)

        // A revision this build cannot parse. Nothing writes one — `ConfigRevision.next`
        // is meant to produce counters — but the column is text, and a store that has
        // been through a hand edit or a bad import can hold one.
        try store.database.write { db in
            try db.execute(
                sql: "UPDATE providerInstance SET configRevision = ? WHERE id = ?",
                arguments: ["config-r1", Self.instanceID.rawValue]
            )
        }

        _ = try? store.reconfigureProviderInstance(
            id: Self.instanceID,
            displayName: "renamed",
            baseURL: nil
        )

        let after = try store.providerInstance(id: Self.instanceID)
        #expect(
            after?.configRevision.rawValue != ConfigRevision.initial.rawValue,
            """
            an unparseable revision was renumbered to \
            \(ConfigRevision.initial.rawValue). That is a revision some run may already \
            have been frozen against, so the instance moved underneath a run whose check \
            still passes. Got \(String(describing: after?.configRevision.rawValue)).
            """
        )
    }
}

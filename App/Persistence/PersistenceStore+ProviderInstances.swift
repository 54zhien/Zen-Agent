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

    func saveProviderInstance(_ instance: ProviderInstance, at now: Date = Date()) throws {
        try database.write { db in
            var record = Self.providerInstanceRecord(from: instance, at: now)
            // Created-once, preserved across the upsert. Read inside the transaction so
            // two concurrent saves cannot both decide the row is new.
            record.createdAt = try ProviderInstanceRecord
                .fetchOne(db, key: instance.id.rawValue)?.createdAt ?? now
            try record.upsert(db)
        }
    }

    /// Edits the configuration and bumps the revision in one step.
    ///
    /// The revision is bumped here rather than by the caller because it has to be
    /// impossible to change an instance without changing what a frozen run compares
    /// against. A caller that edited the display name and forgot the revision would
    /// leave every paused run still believing it matched.
    ///
    /// `credentialReference` is left alone — attaching or detaching a credential is a
    /// separate act, and folding it in would mean an edit could silently drop one.
    @discardableResult
    func reconfigureProviderInstance(
        id: ProviderInstanceID,
        displayName: String,
        baseURL: URL?,
        at now: Date = Date()
    ) throws -> ProviderInstance {
        guard var instance = try providerInstance(id: id) else {
            throw PersistenceError.providerInstanceNotFound(id)
        }
        instance.displayName = displayName
        instance.baseURL = baseURL
        instance.configRevision = instance.configRevision.next
        try saveProviderInstance(instance, at: now)
        return instance
    }

    /// Attaches a credential reference, or detaches it with `nil`.
    ///
    /// Detaching is how an instance becomes "unauthenticated but kept". The configuration
    /// stays; only the pointer to the secret goes.
    @discardableResult
    func attachCredential(
        _ reference: CredentialReference?,
        toInstance id: ProviderInstanceID,
        at now: Date = Date()
    ) throws -> ProviderInstance {
        guard var instance = try providerInstance(id: id) else {
            throw PersistenceError.providerInstanceNotFound(id)
        }
        instance.credentialReference = reference
        try saveProviderInstance(instance, at: now)
        return instance
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
            credentialReference: record.credentialID.map {
                CredentialReference(
                    id: $0,
                    kind: CredentialKind(rawValue: record.credentialKind ?? "") ?? .apiKey
                )
            }
        )
    }

    private static func providerInstanceRecord(from instance: ProviderInstance, at now: Date) -> ProviderInstanceRecord {
        ProviderInstanceRecord(
            id: instance.id.rawValue,
            providerID: instance.providerID.rawValue,
            displayName: instance.displayName,
            baseURL: instance.baseURL?.absoluteString,
            configRevision: instance.configRevision.rawValue,
            credentialID: instance.credentialReference?.id,
            credentialKind: instance.credentialReference?.kind.rawValue,
            // Replaced inside the write block, where the existing row can be read.
            createdAt: now,
            updatedAt: now
        )
    }
}

/// The stored shape. `createdAt` is set on first write and preserved by the upsert's
/// update path — see `saveProviderInstance`.
struct ProviderInstanceRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "providerInstance"

    var id: String
    var providerID: String
    var displayName: String
    var baseURL: String?
    var configRevision: String
    var credentialID: String?
    var credentialKind: String?
    var createdAt: Date
    var updatedAt: Date
}

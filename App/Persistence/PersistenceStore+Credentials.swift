import Foundation
import GRDB

/// Non-secret credential metadata, stored in GRDB.
///
/// The other half of the credential boundary lives in `App/Credential/`, which never
/// imports GRDB. This file is the seam: it can only ever be handed a `CredentialMetadata`,
/// and everything in that type is safe to store — an opaque id, a counter, an optional
/// opaque fingerprint and a status.
///
/// Note what is **not** here and cannot be: `SecretValue` is not `Codable`, so no
/// arrangement of these types can put a secret in the database. That is a compile-time
/// property rather than a rule to remember.
extension PersistenceStore: CredentialMetadataRepository {

    func loadMetadata(for reference: CredentialReference) throws -> CredentialMetadata? {
        try database.read { db in
            try CredentialMetadataRecord
                .filter(Column("credentialID") == reference.id)
                .filter(Column("kind") == reference.kind.rawValue)
                .fetchOne(db)
                .map(Self.metadata(from:))
        }
    }

    func saveMetadata(_ metadata: CredentialMetadata) throws {
        let record = Self.record(from: metadata)
        try database.write { db in
            try record.upsert(db)
        }
    }

    func deleteMetadata(for reference: CredentialReference) throws {
        try database.write { db in
            try CredentialMetadataRecord
                .filter(Column("credentialID") == reference.id)
                .filter(Column("kind") == reference.kind.rawValue)
                .deleteAll(db)
        }
    }

    // MARK: - Row mapping

    private static func metadata(from record: CredentialMetadataRecord) -> CredentialMetadata {
        CredentialMetadata(
            reference: CredentialReference(
                id: record.credentialID,
                kind: CredentialKind(rawValue: record.kind) ?? .apiKey
            ),
            bindingGeneration: record.bindingGeneration,
            principalFingerprint: record.principalFingerprint,
            status: CredentialStatus(rawValue: record.status) ?? .authenticationRequired,
            updatedAt: record.updatedAt
        )
    }

    private static func record(from metadata: CredentialMetadata) -> CredentialMetadataRecord {
        CredentialMetadataRecord(
            credentialID: metadata.reference.id,
            kind: metadata.reference.kind.rawValue,
            bindingGeneration: metadata.bindingGeneration,
            principalFingerprint: metadata.principalFingerprint,
            status: metadata.status.rawValue,
            updatedAt: metadata.updatedAt
        )
    }
}

/// The stored shape. Separate from `CredentialMetadata` because the domain type should
/// not have to care that the table is keyed on two columns.
struct CredentialMetadataRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "credentialBinding"

    var credentialID: String
    var kind: String
    var bindingGeneration: Int
    var principalFingerprint: String?
    var status: String
    var updatedAt: Date

    var id: String { "\(credentialID)#\(kind)" }
}

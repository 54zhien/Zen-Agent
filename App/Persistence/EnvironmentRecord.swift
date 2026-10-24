import Foundation
import GRDB

struct EnvironmentVariableRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "environmentVariable"
    let id: String
    let scope: String
    let key: String
    var currentRevisionID: String
    var state: String
    let createdAt: Date
    var updatedAt: Date
}

struct EnvironmentRevisionRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "environmentRevision"
    let id: String
    let variableID: String
    let kind: String
    let plainValue: String?
    let credentialReferenceID: String?
    let credentialKind: String?
    let credentialGeneration: Int?
    let createdAt: Date

    var storedValue: EnvironmentStoredValue {
        get throws {
            if kind == "plain", let plainValue, credentialReferenceID == nil {
                return .plain(plainValue)
            }
            guard kind == "secret", plainValue == nil, let id = credentialReferenceID,
                  credentialKind == CredentialKind.environmentSecret.rawValue,
                  let generation = credentialGeneration, generation > 0 else { throw EnvironmentError.erasedDependency }
            return .secret(.init(reference: .init(id: id, kind: .environmentSecret), generation: generation))
        }
    }
}

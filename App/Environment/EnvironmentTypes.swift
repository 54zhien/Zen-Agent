import Foundation

enum EnvironmentError: Error, Equatable, Sendable {
    case invalidKey, invalidValue, duplicateKey, editConflict, notFound, invalidScope
    case validationUnavailable, unsafeContent, erasedDependency, missingReference, cycle, secretInterpolation
}

struct EnvironmentScope: Codable, Sendable, Equatable, Hashable {
    let skillID: String?
    static let global = EnvironmentScope(skillID: nil)
    static func skill(_ id: String) -> Self { .init(skillID: id) }
    var storageID: String { skillID.map { "skill:\($0)" } ?? "global" }
}

struct EnvironmentRevisionReference: Codable, Sendable, Equatable, Hashable {
    let variableID: String
    let revisionID: String
}

enum EnvironmentStoredValue: Codable, Sendable, Equatable {
    case plain(String)
    case secret(CredentialBindingSnapshot)
}

struct EnvironmentItem: Sendable, Equatable, Identifiable {
    let id: String
    let revisionID: String
    let scope: EnvironmentScope
    let key: String
    let value: EnvironmentStoredValue
    let updatedAt: Date
    var reference: EnvironmentRevisionReference { .init(variableID: id, revisionID: revisionID) }
}

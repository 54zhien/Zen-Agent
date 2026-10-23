import Foundation

struct SkillActivationReference: Codable, Sendable, Equatable {
    let skillID: String
    let revisionID: String
    let environmentReferences: [EnvironmentRevisionReference]
    let environmentFingerprint: String
}

struct SkillContext: Sendable, Equatable {
    let reference: SkillActivationReference
    let name: String
    let instructions: String
}

struct ExtensionDependencySummary: Sendable, Equatable {
    var skillNames: [String] = []
    var activeRunIDs: [String] = []
}

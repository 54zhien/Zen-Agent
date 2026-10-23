import Foundation

struct SkillActivationReference: Codable, Sendable, Equatable {
    let skillID: String
    let revisionID: String
    let environmentReferences: [EnvironmentRevisionReference]
    let environmentFingerprint: String

    static func areWellFormed(_ references: [Self]) -> Bool {
        references.count <= SkillRouter.maximumActivatedSkills
            && Set(references.map(\.skillID)).count == references.count
            && references.allSatisfy { item in
                identifier(item.skillID) && identifier(item.revisionID)
                    && item.environmentReferences.count <= 32
                    && Set(item.environmentReferences.map(\.variableID)).count == item.environmentReferences.count
                    && item.environmentReferences.allSatisfy { identifier($0.variableID) && identifier($0.revisionID) }
                    && item.environmentFingerprint.range(of: "^env-v1:[a-f0-9]{64}$", options: .regularExpression) != nil
            }
    }

    private static func identifier(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 128
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
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

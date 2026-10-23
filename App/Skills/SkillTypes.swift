import Foundation

enum SkillError: Error, Equatable, Sendable {
    case invalidDefinition, notFound, editConflict, builtInReadOnly, disabled, missingDependency
    case erasedDependency, unsafeContent, validationUnavailable, resourceInUse
}

enum SkillSource: String, Codable, Sendable { case builtIn, userCreated }

struct SkillDefinition: Codable, Sendable, Equatable {
    var name: String
    var summary: String
    var instructions: String
    var requiredTools: [String] = []
    var optionalTools: [String] = []
    var requiredMCPServers: [String] = []
    var environmentKeys: [String] = []
    var triggerTerms: [String] = []
}

struct SkillItem: Sendable, Equatable, Identifiable {
    let id: String
    let revisionID: String
    let source: SkillSource
    let definition: SkillDefinition
    let enabled: Bool
    var pendingDeletion: Bool = false
}

struct SkillDependencyStatus: Sendable, Equatable {
    var missing: [String] = []
    var notices: [String] = []
    var isAvailable: Bool { missing.isEmpty }
}

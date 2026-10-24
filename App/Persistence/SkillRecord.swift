import Foundation
import GRDB

struct SkillRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "skillRecord"
    var id: String
    var source: SkillSource
    var enabled: Bool
    var currentRevisionID: String
    var state: String
    var createdAt: Date
    var updatedAt: Date
}

struct SkillRevisionRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "skillRevision"
    var id: String
    var skillID: String
    var definition: String
    var createdAt: Date

    var decodedDefinition: SkillDefinition {
        get throws {
            guard let result = try? JSONDecoder().decode(SkillDefinition.self, from: Data(definition.utf8)),
                  SkillValidation.allows(result) else { throw SkillError.erasedDependency }
            return result
        }
    }
}

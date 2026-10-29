import Foundation

enum SkillValidation {
    static func allows(_ definition: SkillDefinition) -> Bool {
        guard text(definition.name, limit: 256, required: true),
              text(definition.summary, limit: 512),
              text(definition.instructions, limit: 8_192, required: true),
              EnvironmentValidation.allowsPlain(definition.instructions),
              identifiers(definition.requiredTools, allowingMCPToolIDs: true),
              identifiers(definition.optionalTools, allowingMCPToolIDs: true),
              identifiers(definition.requiredMCPServers),
              Set(definition.requiredTools).isDisjoint(with: definition.optionalTools),
              definition.environmentKeys.count <= 32,
              Set(definition.environmentKeys).count == definition.environmentKeys.count,
              definition.environmentKeys.allSatisfy(EnvironmentValidation.allowsKey),
              Set(EnvironmentValidation.references(in: definition.instructions)).isSubset(of: Set(definition.environmentKeys)),
              definition.triggerTerms.count <= 16,
              Set(definition.triggerTerms).count == definition.triggerTerms.count,
              definition.triggerTerms.allSatisfy({ text($0, limit: 128, required: true) })
        else { return false }
        return true
    }

    private static func text(_ value: String, limit: Int, required: Bool = false) -> Bool {
        value.utf8.count <= limit && (!required || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) || [9, 10, 13].contains($0.value) }
    }

    private static func identifiers(_ values: [String], allowingMCPToolIDs: Bool = false) -> Bool {
        values.count <= 16 && Set(values).count == values.count && values.allSatisfy { value in
            value.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil
                || (allowingMCPToolIDs && MCPToolExecutable.serverID(forToolID: value) != nil)
        }
    }
}

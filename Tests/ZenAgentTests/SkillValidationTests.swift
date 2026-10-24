import Foundation
import Testing
@testable import ZenAgent

@Suite("Stage8 bounded Skill definition syntax")
struct SkillValidationTests {
    @Test func definitionBounds() {
        let valid = SkillDefinition(name: "核验", summary: "简短说明", instructions: "Use ${REGION}.",
            requiredTools: ["calculator"], environmentKeys: ["REGION"], triggerTerms: ["计算", "calculate"])
        #expect(SkillValidation.allows(valid))
        var bad = valid; bad.name = " "
        #expect(!SkillValidation.allows(bad))
        bad = valid; bad.instructions = String(repeating: "a", count: 8_193)
        #expect(!SkillValidation.allows(bad))
        bad = valid; bad.environmentKeys = []
        #expect(!SkillValidation.allows(bad))
        bad = valid; bad.requiredTools = ["../tool"]
        #expect(!SkillValidation.allows(bad))
        bad = valid; bad.instructions = "unsafe\u{0}control"
        #expect(!SkillValidation.allows(bad))
        bad = valid; bad.triggerTerms = Array(repeating: "trigger", count: 17)
        #expect(!SkillValidation.allows(bad))
    }
}

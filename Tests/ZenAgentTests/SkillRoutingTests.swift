import Testing
@testable import ZenAgent

@Suite("Stage8 local Skill routing")
struct SkillRoutingTests {
    @Test("enabled definitions are relevant subsets, not a complete injected catalog")
    func relevantSubset() {
        let candidates = Self.candidates()
        #expect(SkillRouter.select(query: "请计算 8 * 7", candidates: candidates).map(\.id) == ["calculate"])
        #expect(SkillRouter.select(query: "Please READ FILE and summarize it", candidates: candidates).map(\.id) == ["files"])
        #expect(SkillRouter.select(query: "你好，今天的心情如何", candidates: candidates).isEmpty)
        #expect(SkillRouter.select(query: "Please miscalculate the estimate", candidates: candidates).isEmpty)
    }
    @Test("disabled definitions never route and ties have a stable bounded order")
    func bounded() {
        let definitions = (0..<4).reversed().map { n in
            SkillItem(id: "skill-\(n)", revisionID: "v1", source: .userCreated,
                definition: SkillDefinition(name: "Workflow", summary: "", instructions: "Read carefully", triggerTerms: ["inspect"]), enabled: n != 0)
        }
        #expect(SkillRouter.select(query: "inspect", candidates: definitions).map(\.id) == ["skill-1", "skill-2"])
    }
    static func candidates() -> [SkillItem] {
        [SkillItem(id: "calculate", revisionID: "v1", source: .builtIn,
            definition: SkillDefinition(name: "计算核验", summary: "", instructions: "Check arithmetic", triggerTerms: ["计算", "calculate"]), enabled: true),
         SkillItem(id: "files", revisionID: "v1", source: .builtIn,
            definition: SkillDefinition(name: "文件阅读", summary: "", instructions: "Read requested files", triggerTerms: ["阅读文件", "read file"]), enabled: true)]
    }
}

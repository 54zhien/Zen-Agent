import Foundation

enum SkillCatalog {
    static let items: [SkillItem] = [
        .init(id: "zen.calculate", revisionID: "builtin-calculate-v1", source: .builtIn,
            definition: .init(name: "计算核验", summary: "用计算工具核验用户要求的算术，并说明结果。", instructions: """
            For arithmetic requested by the user, use the available calculator when appropriate and check the expression against the request. Explain the actual returned result. If the tool is unavailable or fails, state that limitation; never invent a tool result. Follow the current user request and the independent Tool policy and approval decisions.
            """, requiredTools: ["calculator"], triggerTerms: ["计算", "算一下", "calculate", "arithmetic"]), enabled: false),
        .init(id: "zen.reading", revisionID: "builtin-reading-v1", source: .builtIn,
            definition: .init(name: "文件阅读", summary: "读取用户指定的文件，区分原文、摘要与推断。", instructions: """
            Read only files explicitly requested or attached by the user through the available Files tool. Distinguish source text, summary and inference. Report inaccessible or missing data accurately. Reading does not authorize editing, creating, exporting or deleting a file. Respect the current user request and independent Tool policy and approval decisions.
            """, requiredTools: ["files"], triggerTerms: ["阅读文件", "总结文件", "read file", "summarize file"]), enabled: false)
    ]
}

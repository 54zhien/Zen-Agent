---
status: accepted
date: 2026-09-19
---

# 用 XcodeGen 生成工程，不把 .xcodeproj 纳入版本控制

Stage 0 直接引入 XcodeGen：`project.yml` 与 `.xcconfig` 是工程配置的唯一真值来源，
`.xcodeproj` 在本地与 CI 上按需生成，并加入 `.gitignore`。

## 为什么需要这个决定

本项目的开发方式有三个特点叠加：开发机是 Windows、大量改动由 AI 直接编辑文件完成、
本地无法执行 Xcode build。而 Xcode 工程文件 `project.pbxproj` 是几千行、结构高度冗余、
每条记录的 UUID 相互交叉引用的格式——它恰恰是最不适合被逐段文本编辑的文件。
让人或 AI 反复直接改它，冲突和静默损坏只是时间问题，而且因为本地不能编译，
损坏往往要到 CI 上才暴露。

XcodeGen 把这份复杂度收敛成一个声明式的 `project.yml`，改动是增删条目而不是改写 UUID 图。
同时因为配置文本化了，工程结构的变更可以在 diff 里被 review。

## Consequences

- `.xcodeproj` / `.xcworkspace` 不入库，改用 `.gitignore` 忽略。这修正了原 `.gitignore`
  结尾那句「Keep source, project files ... versioned」——**设计笔记与资源入库，生成的工程文件不入库**。
- CI 的构建步骤需要在 build 之前插入一步生成工程。
- 依赖管理（SPM 包版本锁定）仍需另行处理，XcodeGen 不替代它。
- 新增 `project.yml` 与 `.xcconfig` 之后，最低 iOS deployment target、
  Swift 版本、签名配置都应当只在这些文件里定义一次，不再散落在笔记或 CI 脚本里。

# Zen Agent — Stage 0 执行清单

> 设计依据在 Blueprint 仓库；本文件只跟踪**实现侧**的工作。
> Stage 0 的边界：**只建立真实基线，不实现任何产品功能**。

## 已定决策（不再重开）

- **最低 iOS deployment target = iOS 26**。`BGContinuedProcessingTask`（后台继续处理）
  被当作正式核心能力而非可选项，因此不留 `#available` 降级分支。
  代价：iOS 26 刚发布，上线时可安装设备基数很小，真机验证设备必须能升到 26。
- **Swift 6 language mode + 严格并发 complete**。
- 两者都定义在 `Config/Common.xcconfig`，**不写在 `project.yml`**——
  构建设置会覆盖 xcconfig，两处声明会让 xcconfig 失去权威性。
- 决策依据：`Zen-Agent-Blueprint → Design/Zen Agent 开发规划.md §10`。

## 增量 1：工程 Bootstrap

- [x] `project.yml`（app + iOS 单测 + macOS spike 三个 target；ZenAgent / PersistenceSpike 两个 scheme）
- [x] `Config/{Common,Debug,Release}.xcconfig` + `Secrets.xcconfig.example`
- [x] 最小 App（无任何产品功能）+ 冒烟测试
- [x] `Spikes/Persistence/` 接线验证：GRDB 能开库、SwiftData 能建 container
- [x] `Spikes/Persistence/README.md` — A–G 场景规格、判定标准、**删除规则**
- [x] `.github/workflows/ci.yml` — hygiene job + build/test job
- [x] `AGENTS.md` / `README.md` / `.gitignore`
- [x] `Docs/ADR/0001`（持久化选型推迟到 spike）、`0002`（XcodeGen）
- [x] 静态校验：YAML 解析、scheme/target/sources 交叉引用、needs 引用、路径存在性、gitignore 覆盖

**未验证**：本机是 Windows 且无 Swift 工具链，以上**一行代码都没有编译过**。
CI 是唯一验证手段。

- [ ] **CI 首次运行转绿**（预计需要修：XcodeGen 语法、SPM 解析、Simulator 名称）
- [ ] 记录首次 CI 失败的真实原因，不要靠猜修改

## 增量 2：Persistence Spike（CI 绿之前不开始）

- [ ] `SpikeHarness.swift` — 共享协议，两个引擎实现同一组操作
- [ ] `SwiftDataHarness.swift`
- [ ] `GRDBHarness.swift`
- [ ] `ScenarioTests.swift` — A–G 七个场景，**两个引擎跑完全相同的测试**

| # | 场景 | 核心问题 |
|---|---|---|
| A | Atomic send commit | User Message + Parent Run + frozen seed 一个事务完成，崩溃后无半状态 |
| B | Active Parent Run unique | 「至多一个**非终态** Parent Run」在并发下被原子保证 |
| C | Indeterminate write | dispatch 后崩溃 → recover 不得自动重发，落为 indeterminate |
| D | Migration recovery | V1→V2 可重复跑、可中断、不靠删库 |
| E | Delete / Undo | `visible → pendingDeletion →(Undo\|Finalize)`；Undo 窗口内正文真实存在 |
| F | Tombstone | Conversation finalize 后正文可删，最小操作追踪记录不被 cascade 抹掉 |
| G | Streaming write pressure | 每 token 写库 vs batch/snapshot 的写入次数与阻塞 |

**B 是决定性的一条**：它要求**条件唯一性**，两个引擎都没有一等 API，
需要可空 active-slot 列 + 唯一索引的 workaround。已在 `EngineWiringTests` 提前单线程验证。
ADR 必须区分「业务不变量」与「物理 schema 手段」——**不要因为 spike 用了某个字段
就把它写成正式数据库设计**。

## 增量 3：选型与落地

- [ ] 按 ADR-0001 的对比表逐项填两个引擎的实测结果，**不能写「看起来更专业」或「Apple 原生所以更好」**
- [ ] `Docs/ADR/0001-persistence-engine.md` 落定：Decision / Context / Alternatives / Evidence / Trade-offs / Consequences
- [ ] **记录落选引擎的代价**（将来重新考虑时理由应当已经写下来）
- [ ] 建立正式 Persistence skeleton
- [ ] **把关键不变量测试迁进正式 Tests**（见下），确认 CI 仍绿
- [ ] **之后**才删除一次性 spike 实现与 `project.yml` 里的 `PersistenceSpikeTests` target

要长期保护的 regression test（**不能跟着 spike 一起删**）：
`active Parent Run uniqueness` / `atomic send` / `indeterminate recovery` / `migration`。

## Stage 0 完成判据

- [x] 独立代码仓库建立
- [x] Blueprint 恢复为纯设计仓库
- [ ] Blueprint baseline SHA 已记录在 `README.md`
- [ ] XcodeGen 可从纯源码生成工程（CI 证实）
- [x] `.xcodeproj` 不入库
- [ ] Debug / Release config 正常（CI 证实）
- [x] deployment target 已确定
- [ ] CI build 成功
- [ ] Unit Test 成功
- [x] secret / signing 文件受 `.gitignore` + CI hygiene 保护
- [ ] SwiftData / GRDB A–G Spike 完成
- [ ] ADR-0001 已明确选型
- [ ] 正式 Persistence skeleton 已落地
- [ ] 关键 Spike 测试已迁成长期 regression tests
- [ ] Disposable Spike 已删除
- [ ] **当前仍没有偷偷实现 Stage 1+ 产品功能**

全部满足 → Stage 0 DONE → 进入 Stage 1（Data / Credential / Provider / DeepSeek Transport / Streaming）。

## Review

（Stage 0 结束后回填）

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

## 增量 2：Persistence Spike（CI 已转绿）

**CI 状态：全绿**（run 35423406385）。11 个测试 4 个 suite 通过 + 1 个 known issue。

场景权重（产品给定，决定证据如何汇总）：B/C/D 最高 · A/G 中高 · E/F 中等。
判读原则：若 GRDB 在 B+C+D 上明显更强，即使 SwiftData 在 E/F 更省代码，仍偏向 GRDB。

| # | 权重 | 场景 | SwiftData | GRDB |
|---|---|---|---|---|
| B | 最高 | Active Parent Run unique | ❌ **已知缺陷** `won=3` | ✅ |
| C | 最高 | 崩溃窗口两态可区分 | ✅ | ✅ |
| D | 最高 | 迁移可中断重跑 | ⬜ 未做 | ✅ |
| A | 中高 | Atomic send commit | ⬜ | ⬜ |
| G | 中高 | Streaming 写入压力 | ⬜ | ⬜ |
| E | 中 | Delete / Undo | ⬜ | ⬜ |
| F | 中 | Tombstone | ⬜ | ⬜ |

**3/7 完成。GRDB 目前只在 B 上领先，C 是平局——远没到能选型的时候。**

- [x] 接线验证（两个引擎能构建、能跑）
- [x] 声明式约束语义测定（SwiftData `#Unique` = upsert）
- [x] B：并发对照，两引擎同形状、同计分
- [x] C：崩溃窗口两态（**平局**）
- [x] D：GRDB 半边
- [ ] **D：SwiftData 半边**（versioned-schema 宏密集，中断路径在 container init 内隐式发生，问题形状不同）
- [ ] A / E / F / G

### 已定的处理方式

- **SwiftData 的 B 用 `withKnownIssue` 标记**，不是删除也不是放过：需求仍在代码里，
  CI 保持绿以免真正的回归淹没在常红噪音里，若哪天 unexpected pass 则提示 ADR 需重审。
- **ADR 必须区分「业务不变量」与「物理 schema 手段」**——不要因为 spike 用了某个字段
  就把它写成正式数据库设计。
- **串行 owner 退路的覆盖范围**（产品已裁定，见 `Docs/ADR/0001`）：
  同进程 ✅ · 多 Scene ✅（不是进程边界）· App Extension/第二进程 ❌ · 绕过 owner 的其他写路径 ❌
- 场景跑完后**先迁移不变量 regression test，再删一次性实现**（见 `Spikes/Persistence/README.md`）

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

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

## Stage 0 完成判据 —— 全部满足

- [x] 独立代码仓库建立（`54zhien/Zen-Agent`）
- [x] Blueprint 恢复为纯设计仓库
- [x] Blueprint baseline SHA 已记录在 `README.md`（`6b12e46`）
- [x] XcodeGen 可从纯源码生成工程（CI 每次都从零 `xcodegen generate`）
- [x] `.xcodeproj` 不入库（CI hygiene 断言）
- [x] Debug / Release config 正常
- [x] deployment target 已确定（iOS 26，`Config/Common.xcconfig` 唯一真值）
- [x] CI build 成功
- [x] Unit Test 成功（39 条 / 8 suite）
- [x] secret / signing 文件受 `.gitignore` + CI hygiene 保护
- [x] SwiftData / GRDB A–G Spike 完成
- [x] ADR-0001 Accepted，V1 使用 GRDB
- [x] 正式 Persistence skeleton 已落地（`App/Persistence/`，1045 行）
- [x] 关键 Spike 测试已迁成长期 regression tests（7/7）
- [x] Disposable Spike 已删除，且删除后 CI 仍全绿
- [x] **没有偷偷实现 Stage 1+ 产品功能**（`App/` 下只有 `Persistence/`）

**Stage 0 DONE。**

## 收尾记录

- **Gate 验证于提交 `9efce76`**，对应 CI run `35429883780` → success
  （记录的是「Gate 在哪个提交上被验证」，不是「HEAD 现在指向哪」——之后的 housekeeping
  提交会让 HEAD 前移，但不影响 Gate 的成立。）
- 正式 Persistence 代码 1045 行；测试代码 1225 行（测试多于实现，符合预期）
- Blueprint baseline `6b12e46` 已确认在**远端**可解析（见下）

### Housekeeping：baseline 曾指向一个不存在的远端对象

Stage 0 期间提交了 Blueprint 的 v0.9 收口（`6b12e46`）但**从未推送**——
Zen-Agent 的 README 却已经把它记为 baseline。结果是一份指向只有本机才有的 commit 的记录，
任何人 clone 都 fetch 不到。

已推送 Blueprint（fast-forward `7237487` → `6b12e46`），远端 main 与该 SHA 一致，
**baseline 值本身没有改动**——需要修的从来不是那个值，而是它在远端是否真实存在。

**教训**：记录一个 SHA 之前先确认它能被解析。写在文档里的引用和代码里的符号一样，
存在性的验证不能省。

### 过程中值得留下的教训

1. **仓库是 private 时拿不到 runner。** 连续 5 次尝试 `runner_name: ""` / `steps: 0`，
   一开始只有 macOS job 失败，后来 ubuntu 也失败。诊断分支实验排除了「macOS 容量」假设，
   指向账户级限制；改成 public 后立刻恢复。**环境问题不能当成代码通过，也不能当成代码失败。**
2. **`ab085cd` 第一次真正执行就通过**——但它在此之前完全未编译过。
   小步提交 + 每次 CI 验证的价值在这里：失败时错误精确到文件和行。
3. **测试抓出了实现的 bug**：`undoDeletion` 没有状态守卫，
   对已 finalize 的会话撤销会把标志翻回 `visible` 而正文已删。
   当时我的第一反应是写测试记录这个行为——那会把 bug 固化成设计。**改成修实现。**

## Review

Stage 0 的产出不是功能，是**一条可信的基线**：工程可从源码重建、CI 每次证伪、
持久化引擎有实测依据、七条不变量有长期守卫、且没有任何 Stage 1 内容被提前实现。

下一阶段（Stage 1）的第一件事应是审计本仓库真实状态，而不是从蓝图假设出发。

## 增量 6：P1 — ToolCall 副作用状态机 + 领域 mutation 的 0-row 守卫

> 双脑全量审查对账后的第一项修复。任务卡给了完整规格：X1 tombstone 筛选从
> `recoveryDisposition` 派生；X2 四个 mutation（markToolCallDispatched / finishToolCall /
> finishRun / finishPart）统一 guardedUpdate（WHERE 前置状态 + changesCount + typed error）；
> 复活 `runNotFound`、新增 `toolCallNotFound`。
> 本机无 Swift 工具链，CI 是唯一编译验证；探针提交预期红（lessons #4）；每步等 CI
> 结束后再推下一步（concurrency.cancel-in-progress 会让同 ref 并发运行互相取消）。

分支：`fix/guarded-domain-mutations`（首次误推的 `fix/toolcall-side-effect-guards` 因 GRDB `IN (?)` 写法无法编译被废弃，保留在远端未删；新分支按 corrected 提交重建）

- [x] A `feat: ToolCallState: CaseIterable`（Records.swift；X1/X2 派生式集合的前提）→ CI 绿（run 35505203286）
- [x] B `test: X1 探针——finalize 后 tombstone 存在 == mustReportIndeterminate，遍历 allCases`（预期红：.dispatched 被物理删除）→ CI 进行中（run 35505871999）
- [x] C `fix: tombstone 集合从 recoveryDisposition 派生`（Deletion.swift；用 databaseQuestionMarks 显式占位符——GRDB 7 不支持 IN (?) 数组参数）→ 已提交待推
- [x] D `test: X2 探针——0-row 与非法转换必须拒绝`（预期红：四处静默成功）→ 已提交待推
- [x] E `fix: 四个 mutation guardedUpdate（含 ToolCallState.isTerminal、RunState: CaseIterable、refuseMissedStateUpdate helper）` → 已提交待推
- [x] F `test: 探针升级为 typed 断言 + 钉住合法转换` → 已提交待推
- [ ] 推送节奏：B 红确认 → C → D 红确认 → E → F，每步等 CI 结束（concurrency.cancel-in-progress）
- [ ] 收尾：/code-review 复核分支 diff；lessons 追加；交付物（分支+sha+log+红绿过程+CI id+偏离说明）


## 增量 7：P2 — 凭据绑定原子性（X3 + A-5 + X4）

> **将调用**：/codebase-design（SecretBackend 版本化 + frozen resolve 单临界区接口设计）、
> /security-review（收尾：对分支 diff 复核安全属性）。zh-readme / zh-code-reviewer / 其余 skill 与任务意图不匹配。

分支：`fix/credential-binding-atomicity`（已存在，指向 main 尖端 `c68c41b`，干净）。
CI 节奏：本机无 Swift toolchain（PATH/常见安装目录均无，docker 无法编译 iOS 目标），CI 是唯一编译验证
（lessons #4）。**本续轮（A-5 + X4）为 print-mode 一次性会话**：不等待任何 CI run，探针红绿判断由
编排者在会话外核对；本会话边界 = 代码 + 提交 + 推送。探针/修复的预期红绿写进 commit message。

### 设计决策（实现前定死，codebase-design 复核后微调）

- **X3 版本化 secret**：`SecretBackend.store/load/delete` 带 `generation`；keychain account 键 =
  `"\(id)#\(generation)"`（`KeychainSecretBackend.baseQuery`）；in-memory 同格式复合键，`storedSecret(for:)`
  同步带 generation（现为死代码，改签名保持替身诚实）。
- **rebind 顺序 = store(gen+1) → saveMetadata(gen+1) → delete(旧 gen 键)**。saveMetadata 失败时旧键完好，
  旧 run 继续读到 A；delete 只在元数据提交后清理被替换的键（崩溃后残留旧键由下一次 rebind 自愈）。
  不采用「先 metadata 后 secret」（任务卡明令禁止——只是换个方向错配），不采用 delete-before-save
  （saveMetadata 失败会让旧 run 从「读到 A」降级为「读不到」）。
- **A-5 单临界区**：`CredentialStoring.resolve(frozenReference:generation:)` — 一次 `loadMetadata`
  同时判存在性、status、generation，再按冻结 generation 取秘密；generation 不匹配抛新 case
  `CredentialError.bindingMoved(reference, frozenGeneration:, currentGeneration:)`。
  秘密读取按冻结 generation 定键，元数据提交后的任何 rebind 在物理上无法污染本次读（读到的键要么
  是旧值、要么已删）。`FrozenConfiguration.validate` 不动（matchesBinding 保留作快速路径，
  单临界区在 resolveSecret 里；FrozenCredentialIdentityTests 依赖 validate 的拒绝语义）。
- **X4 穷尽映射**：`CredentialError.failed(reference, underlying:)` ← `SecretBackendError.failed`（不得折成
  unavailable）；`DeepSeekProvider` 映射到新增的具体 case `ProviderError.credentialStorageFailed(reason:)`
  （retryDisposition = doNotRetry；不发明笼统 storageFailure，也不复用 unavailable/missing/rejected——
  三者都会指向错误的用户动作）；`ProviderAvailability` 映射到
  `authenticationRequired(reason: .storageFailed)`（AuthenticationRequirementReason 新 case，
  「用户必须行动」语义成立，且与 loggedOut/providerRejected 可区分）。

### 提交序列（一步一提交，红/绿预期写进 commit message）

- [x] 1 `test: X3 探针——saveMetadata 抛错时旧 generation 不得解析出新秘密`（预期红；含 InMemory 双替身的 failNextSave 开关）— `fe44f6c`，CI 已确认红得对
- [x] 2 `fix: X3——secret 按 generation 版本化，rebind 重排`（预期 (a) 绿，(b)(c) 未写仍无红；含 DeepSeekProviderTests:532 直调 delete 带 gen）— `271622a`
- [ ] 3 `test: A-5 探针——validate 通过后插 rebind 必须 configurationMismatch 且零请求`（预期红；含 metadata 替身 onLoadMetadata 钩子）
- [ ] 4 `fix: A-5——frozen resolve 单临界区，resolveSecret 走 seed 冻结 binding`（预期 (b) 绿；新增 CredentialError.bindingMoved，两个消费方 switch 显式处理）
- [ ] 5 `test: X4 探针——SecretBackend.failed 必须 typed`（预期红；含 InMemorySecretBackend failedReferences 开关；断言用否定式 `is CredentialError`/`is ProviderError` 保证改前可编译）
- [ ] 6 `fix: X4——failed 穷尽映射`（预期全绿；探针升级为 typed 断言 .failed/.credentialStorageFailed）
- [ ] 收尾：/security-review 复核 diff；lessons 追加；交付报告（git log + CI run id + 红绿过程）

### 验证点（防遗漏）

- [ ] 两个 switch（DeepSeekProvider / ProviderAvailability）都显式加新 case，无 default
- [ ] 协议改动牵连：KeychainSecretBackend、InMemorySecretBackend、CredentialStore 三处同步编译
- [ ] Backend.allCases 双后端语义不分叉；keychain e2e（DeepSeekProviderTests:498）正常
- [ ] 错误/日志不打印秘密（SecretValue 空镜像，勿 .revealed 入文案）
- [ ] CI hygiene：import Security 仍在 App/Credential 内、SecretValue 声明位置不变

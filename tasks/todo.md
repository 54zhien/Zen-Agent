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
- [x] 3 `test: A-5 探针——validate 通过后插 rebind 必须 configurationMismatch 且零请求`（预期红；含 metadata 替身 onLoadMetadata 钩子）— `793aace`
- [x] 4 `fix: A-5——frozen resolve 单临界区，resolveSecret 走 seed 冻结 binding`（预期 (b) 绿；新增 CredentialError.bindingMoved，两个消费方 switch 显式处理）— `2fc2906`
- [x] 5 `test: X4 探针——SecretBackend.failed 必须 typed`（预期红；含 InMemorySecretBackend failedReferences 开关；断言用否定式 `is CredentialError`/`is ProviderError` 保证改前可编译）— `1c5976d`
- [x] 6 `fix: X4——failed 穷尽映射`（预期全绿；探针升级为 typed 断言 .failed/.credentialStorageFailed/.storageFailed）— `9b63b42`
- [ ] 收尾：/security-review 复核 diff；lessons 追加；交付报告（git log + CI run id + 红绿过程）——留给编排者（本会话为 print-mode，无 CI 结果）

### 验证点（防遗漏）

- [ ] 两个 switch（DeepSeekProvider / ProviderAvailability）都显式加新 case，无 default
- [ ] 协议改动牵连：KeychainSecretBackend、InMemorySecretBackend、CredentialStore 三处同步编译
- [ ] Backend.allCases 双后端语义不分叉；keychain e2e（DeepSeekProviderTests:498）正常
- [ ] 错误/日志不打印秘密（SecretValue 空镜像，勿 .revealed 入文案）
- [ ] CI hygiene：import Security 仍在 App/Credential 内、SecretValue 声明位置不变

### Review（本续轮，会话内自查）

- **A-5 单临界区**：`CredentialStore.resolve(frozenReference:generation:)` 一次 `loadMetadata` 判
  存在/status/generation，再按冻结 generation 读秘密。status 先于 generation（logged-out 报
  authenticationRequired）。`resolveSecret` 改传 `seed.credentialBinding`，`matchesBinding` 快速
  路径保留在 validate。`ProviderAvailabilityResolver` 继续用旧 `resolve(_:)`（generation 无关）。
- **X4 穷尽映射**：`CredentialError.failed` ← `SecretBackendError.failed`，两处 resolve 经共享
  helper 映射；Provider 层 `credentialStorageFailed`（doNotRetry）、Availability 层
  `authenticationRequired(.storageFailed)`。两个消费方 switch 均无 default。
- **探针可表达性自查**（lessons #3）：探针 b 的窗口（validate 之后、resolve 之前）在旧两步 API
  下可表达——钩子放在 metadata 层而非 secret backend 层（后者在 X3 之后物理上读不到新秘密，
  探针会假绿）。探针 c 用否定式断言保证改前可编译、红在运行时。
- **残留窗口（已知、不可消除）**：frozen resolve 的单次 metadata 读与 secrets.load 之间仍可插
  rebind；此时冻结 generation 的键已被删，表现为安全的失败（credentialMissing），绝不可能是
  新秘密——X3 版本化键保证。两个存储无法共享临界区，这是物理下限。
- **CI 守卫自查**：import Security 仅 App/Credential/KeychainSecretBackend.swift；无新增 GRDB 引用；
  错误文案只含 generation 计数与 reference id（非秘密）；SecretValue 空 mirror 未动。
- **未做**（留给编排者收尾会话）：CI 红绿核对、/security-review、lessons 追加、合并 main。

## 增量 8：P3 — 删除生命周期封口（S1-9 + B-1）

> **将调用**：/code-review（提交后自查 diff）。其余 skill 与任务意图不匹配：本任务是
> 持久层两处守卫 + 回归测试的最小改动，无 UI/前端、无重构需求、无可视化/文档产出。

分支：`fix/deletion-lifecycle-guards`（已存在，指向 main 尖端 `95fe0f1`，干净）。
CI 节奏：本机无 Swift toolchain（lessons #4），CI 是唯一编译验证。**print-mode 一次性会话**：
不等待任何 CI run，探针红绿由编排者在会话外核对；本会话边界 = 代码 + 提交 + 推送。

### 设计决策（实现前定死；/code-review 后三处修订，见 Review）

- **S1-9**：`finalizeDeletion` 在 `database.write` 事务**开头**加守卫。**不能调
  `transition`**（它自己开一个 write，GRDB 禁止嵌套 write，会死锁）。守卫与 `transition`
  现有 guard 同构 → fetch+notFound 抽共享 helper `requireConversation(_:in:)`（传入已打开的
  `db`，在调用方事务内执行），拒绝文案抽 `PersistenceError.invalidLifecycleTransition(expected:actual:)`
  工厂（delete 侧与 send 侧共用，单一事实源）；`transition` 改为调用两者，行为不变，
  由现有 6 条删除测试保护。
- **B-1**：`commitUserTurnAndCreateParentRun` 事务内、`commit.conversation.upsert(db)`
  **之前**读回现有行：`nil`（首次创建）→ 照常 upsert；行与快照均 `.visible` → 照常
  upsert（追加 turn 的正常路径，含 userActiveAt 更新）；任一非 `.visible` → `invalidTransition`。
  不用「无条件 insert(onConflict:)」替换——那会破坏追加消息时更新 userActiveAt 的正常路径。
- **测试 (b) 的播种**：run 用 `runState: .completed`。若 r1 是 active，occupied 检查会在
  upsert 之前抛 `conversationAlreadyHasActiveRun`，复活路径在改前根本不可达，探针会假红
  （lessons #3 可表达性）——completed 后 slot 空出，提交才能走到 upsert，改前红才是真的。

### 提交序列（一步一提交，红/绿预期写进 commit message）

- [x] 1 `test: S1-9 探针`（(a) visible→finalize 必须 invalidTransition 且 body/lifecycle 原样；(c) finalize(missing) 必须 conversationNotFound；预期红）— `d26a548`
- [x] 2 `fix: S1-9`（requireConversation 共享守卫 + 幂等 no-op，finalizeDeletion 事务开头守卫；预期 (a)(c) 绿，finalizeIsIdempotent 保持绿）— `37d74ae`
- [x] 3 `test: B-1 探针`（(b) pendingDeletion 后旧 .visible 快照必须被拒且不复活；(d) undo 后旧 .pendingDeletion 快照不得再隐藏；预期红）— `136a986`
- [x] 4 `fix: B-1`（upsert 前读回校验，双向对称，键用 run 的 conversationID，置于 occupied 检查前；预期 (b)(d) 绿）— `bef5052`
- [x] 5 `chore: 记录 P3 完成与 review notes` — 本 commit

### 验证点（防遗漏）

- [x] import GRDB 只在 App/Persistence/（CI grep 守卫；本会话已本地 grep 确认）
- [x] 正路测试不破：`finalizeRemovesTheBody` 从 `.pendingDeletion` 出发，守卫放行；
      `finalizeIsIdempotent`（IndeterminateTombstoneTests）由 `.finalizedDeletion` no-op 分支保持
- [x] `requireConversation` 重构不改 `transition` 语义（begin/undo 全部现有拒绝路径不变）
- [x] B-1 守卫放行 nil（首建）与「行+快照均 .visible」（追加）；只拦生命周期任一方向被改写
- [x] CI 红绿核对（编排者补记）：P3 合入 main 后 CI run `35514657012` success（tip `bb3256f`）

### Review（/code-review 后修订 + 会话内自查）

code-review（forked，10 个角度）收敛到 5 处真实问题，全部在推送前修复（重放提交序列，
未把红中间态推上分支）：

1. **S1-9 与幂等契约冲突**（5 个角度独立命中）：原方案 `!= .pendingDeletion 一律抛` 会打破
   `IndeterminateTombstoneTests.finalizeIsIdempotent`（两次 finalize 不抛）和行内注释
   「finalising twice must not fail」。改为三态 switch：`.finalizedDeletion` → no-op 返回。
2. **B-1 键错误**：原按规格用 `commit.conversation.id`，与 message/run 实际落地的
   `run.conversationID` 可能不一致（SendCommit 无一致性校验）→ 守卫形同虚设。改用 `conversationID`。
3. **B-1 方向不对称**：只查行不查快照 → undo 后旧 `.pendingDeletion` 快照仍会写回并再隐藏会话。
   守卫补快照侧检查（对称），并新增探针 (d) 覆盖（任务规格未要求，属同一缺陷的镜像方向）。
4. **错误排序**：occupied 检查在守卫前，pendingDeletion+active run 时报「busy」而非「deleted」。
   守卫移到 occupied 检查之前。
5. **拒绝文案三处手写漂移**：抽 `PersistenceError.invalidLifecycleTransition` 工厂，三处共用。

**已知残留（记录，不在本任务范围）**：
- 读回守卫每次 send 多一次主键 SELECT + 全行解码（Angle H 提出单列 String 读或
  conditional UPDATE 替代；按任务规格保留 readback 形状，send 为人类频率，成本可忽略）。
- 行内 lifecycle 出现未知值（新版本写入/损坏）时 `fetchOne` 抛 GRDB RecordError 越过
  类型边界——与既有 `transition` 的暴露模式一致，属 store 全层既有模式，非本 diff 引入的新类。
- 更彻底的方向（Angle I 提出、未采纳）：列限定 upsert（send 路径根本不写 lifecycle）或
  schema 级 BEFORE UPDATE trigger——两者都改 write 语义/加迁移，超出「只做两个子项」。
- `requireConversation` 与 `refuseMissedStateUpdate`（run 侧）是平行机制，统一它们属跨表重构。

**验证边界**：本机无 Swift toolchain，以上红/绿均为**预期**；真实红绿由 CI 判定（编排者核对）。

---

## P4：墓碑不得复制 raw execution intent（A-2，30-merged-plan 优先级 4）

分支 `fix/tombstone-destination-fingerprint`（自 `bb3256f`）。依据是对账结论中两家审查一致的
底线：墓碑的用途是「这次外部操作可能发生过」的长期证据，必须比它所属的 conversation 活得久；
`executionIntent` 是那次调用的**正文**，落进墓碑就等于把用户已删掉的对话内容永久留在库里。

**将调用**：`/code-review`（对本 diff 逐角度审查；本仓库既有实践，lessons #7 正是它查出了
自己引入的缺陷）

### 不变量（本次只有一个）

墓碑行的**任何**字符串字段都不得出现 `executionIntent` 的正文。

### 设计决策（实现前定死）

- **删参数，不发明解析规则**：`destinationFingerprint(from:)` → `destinationFingerprint()`。
  Tool Runtime 至今不存在，任何解析格式都是凭空规定、Runtime 落地时立刻推翻（对账明确
  「不修」的一条）。删掉入参让「intent 进墓碑」在**类型上不可表达**——这是本次唯一的机制，
  机制在签名上，不在注释里（lessons #1/#3）。
- **不做哈希**：哈希只是把「不可读」换个形式。用户拿哈希仍无从核对「那封邮件到底发了没」。
- **具名常量 `unknownDestination = "unknown"`**：值不变（不惊动任何按值比较的地方），名字
  说明它是「给 Runtime 留的位置」而非「今天的派生规则」。函数保留为零参——Runtime 落地时
  它接收的是 Runtime **自己的解析类型**，而非 raw body，所以这仍是那个接缝，不是死代码。
- **`action` 不动**：动作名（`files.write`）是受限标识符，不是正文。
- **测试播种**：给测试私有 helper `seeded(toolCallState:intent:)` 的 `intent` 加默认值，
  其余 4 个调用点字节不变。备选（把 helper 体复制进测试）重复更多行且产生第二条播种路径，不取。
- **准备动作不得就是不变量本身**：播种只走生产 API `commitUserTurnAndCreateParentRun` →
  `createToolCall`，墓碑只走生产 API `beginDeletion` → `finalizeDeletion`；不手写行、不手工置字段。
- **提交形状**：任务规格的完成定义给的是**单个** commit（"提交信息说明「墓碑不再复制 intent
  正文…」"、"commit sha" 单数），故不拆探针 commit。代价：编排者无法从 commit 顺序看到红。
  补偿：静态可证——改动前 `destinationFingerprint(from:)` 对非空 intent 返回原文，新断言
  `destinationFingerprint != intent` 与逐字段 `contains(marker) == false` 在 `bb3256f` 上**必然为假**。

### 提交序列

- [x] 1 `fix: A-2`（删入参 + 具名常量 + 重写注释 + 调用点注释；那条测试断言改为真正的不变量）
      —— 预期绿（`tombstoneMatchesDisposition` / `finalizeIsIdempotent` / `tombstoneSurvivesReopen`
      不碰 fingerprint 内容，只碰存在性，必须保持绿）
      **（编排者补记：会话在写完上述编辑后卡在模型响应上、未提交；编辑已由编排者核对完整并代为提交。）**

### 验证点（防遗漏）

- [x] 全量 grep 调用点（lessons #8）：`destinationFingerprint` 仅 1 处生产调用点 + 1 处测试；
      `OperationTombstoneRecord` / `operationTombstone` 无其他读方
- [x] `destinationFingerprint` 无其他读取者 ⇒ 改值不惊动任何按值比较的断言
- [x] 测试文件不新增 import（CI hygiene 的 GRDB 边界 grep 不受影响）
- [x] CI 红绿核对（编排者补记）：P4 合入 main 后 CI run `35520878436` success（commit `5523ce0`）

---

## P6 / P10 落地记录（编排者，2026-09-21 上午）

两项均已合入 `main`，落地方式都是把已推送分支 **ff** 推到 main（无 merge commit）。

### P6 `fix/error-body-drain-bounds` → `420eb33`

三项修复：error body 读取结束传输并加绝对截止（`StreamTimeoutPolicy.errorBodyDeadline`）、
`ErrorBodyRead` 改为「首个终态获胜」、取消经 `withTaskCancellationHandler` 立即释放 socket
（不再等下一个字节）。

- 审查：Codex 第四轮 **Approve**，依据是状态机终态收敛、锁序、竞态语义与测试承重的**源码级核对**，
  不是 CI 绿。逐条判定上一轮四项整改已在语义上兑现。
- 设计取舍已裁定可接受：为做出「客户端侧屏障」，生产的 `URLSessionHTTPTransport` initializer
  增加了默认 nil 的 `@Sendable` 测试观察闭包（`errorBodyFirstByteHook`）。
  审查结论是保留它比替换它（`#if DEBUG` / 抽象 `AsyncBytes` / delegate）代价更小，合并前不必换。
- CI：`35551721967`（push，head=`420eb33`）success；合入 main 后 CI `35555609276` success。
- **两条已知后续项**（审查判定不阻断本题）：`send(_:)` 仍无 error body cap/deadline；
  Provider 的 `.errorBodyTimeout` 映射缺直接测试（映射在 `DeepSeekProvider.swift:452-463`）。
- 一处非阻断文字瑕疵：`420eb33` 提交信息称 `Task.isCancelled check ahead of the snapshot`，
  实际顺序是 snapshot 在前、检查在后。审查明确判定不值得为此改 sha 重跑 CI。

### P10 `fix/ci-guards-fail-loud` → `b760990`

rebase 到含 P6 的 main 后合入。合并条件按审查要求逐条满足：

- diff 仍只含 `.github/**` 四个文件（`scripts/managed-build-settings-guard.sh`、
  `scripts/guard-selftest-harness.sh`、`workflows/ci.yml`、`workflows/guard-selftest.yml`）。
- 新 sha 上三绿：CI push `35555618171`、CI pull_request `35555619873`、Guard self-test `35555619865`。
- **负向证据到位**：Guard self-test 的步骤列表核对为 Probe 2.1 / 2.2 / 3 / 4 / 5 全部实际执行并通过
  （不是只看 job 结论）。这正是上一轮缺的那一项——「守卫真的会失败」。
- 合入 main 后 CI `35556016905`。

### 仍未合入的

- `docs/status-sync`（`8b66b20`）：文档同步，CI 绿，但**从未经过审查**，按现行规矩不能凭 CI 绿合并。
- `fix/provider-diagnostic-containment`（P5，`1b7e34c`）：需按 `c18-codex-p5-fix-plan.md` 返工，
  并 rebase 到含 P6 的 main。


---

## Stage 3 · S3-01 Typography / 字体注册 / fallback / Dynamic Type

**将调用**：`/code-review`（完成前的自查，唯一匹配的 skill；`run`/`security-review` 不匹配——
本机无 iOS 工具链跑不起 app，本项也不触碰认证/密钥边界）。

**基点** `4be5c05` · 分支 `feat/s3-01-typography` · 工作树 `C:/Users/Azusa/.zen/worktrees/s3-01`。
执行的是已通过覆盖轮复核的 S3-01 执行契约（v2，含覆盖轮后的三处机械修订）。

### 触碰的文件（契约 §0 允许的 7 个）

- [x] `project.yml` —— app target `sources` 增加 `Resources/Fonts`（`buildPhase: resources`）+ `info.properties.UIAppFonts` 三条裸文件名
- [x] `App/Typography/FontRegistry.swift` —— 新建：显式登记 + 把「资产缺失」变成可指名失败
- [x] `App/Typography/Typography.swift` —— 新建：9 个概念角色 → face/字号/textStyle/wght 的 token 层
- [x] `App/ZenAgentApp.swift` —— 只加 `init()`；`body` 与 `StageZeroPlaceholderView` 未动
- [x] `Tests/ZenAgentTests/FontAssetPresenceTests.swift` —— 新建：5 条，只用 main 上既有 API（RED 探针可用）
- [x] `Tests/ZenAgentTests/TypographyTokenTests.swift` —— 新建：9 条
- [x] `AGENTS.md` —— §8 Layout 补 `Typography/` 一行

**未触碰**：`.github/workflows/ci.yml`、`Config/*.xcconfig`、`Resources/Fonts/**`、任何既有测试、
`.xcodeproj`、任何依赖、任何 View。`tasks/**` 只追加。

### 本地静态校验（本机唯一的验证手段）

- [x] `project.yml` YAML 解析通过；`sources` 解析为 `[{path: App}, {path: Resources/Fonts, buildPhase: resources}]`，
      `UIAppFonts` 解析为三条裸文件名；两个 `path` 在磁盘上存在
- [x] CI hygiene 等价 grep：`import GRDB` / `import Security` / `URLSession` 均未越界
- [x] `.xcodeproj` 未被跟踪；`App/Info.plist` 未被创建（XcodeGen 生成物，`.gitignore` 已覆盖）
- [x] `managed-build-settings-guard.sh` 的禁名列（`IPHONEOS_DEPLOYMENT_TARGET` / `SWIFT_VERSION` /
      `SWIFT_STRICT_CONCURRENCY` / `deploymentTarget`）与本次改动无交集
- [ ] **未编译**：本机无 Swift/Xcode，Swift 代码一行都没过编译器。CI 是唯一判据。

### 待 CI 回答的开放项（契约附录 4.1–4.4）

| # | 问题 | 由哪条断言回答 |
|---|---|---|
| 4.1 | 「已登记」的返回码是否稳定 | TypographyTokenTests 第 9 条（登记幂等） |
| 4.2 | 三个 PostScript 名是否与二进制一致 | FontAssetPresenceTests 2/3/5 + TypographyTokenTests 3 |
| 4.3 | descriptor 上是否带得住 variation | TypographyTokenTests 4/5/6 |
| 4.4 | `CTFontCopyVariation` 是否报告 400 | TypographyTokenTests 7 **（预测：可能红；红则上报不削弱）** |

---

## Stage 3 · S3-02 Turn-based Reading Layout + 静态 Timeline

**将调用**：`/apple-design`（SwiftUI 阅读布局的垂直节奏、Dynamic Type 下"布局随文字缩放"、
字重/字号作为一组建立层次——本项唯一的非契约决策点就在这里）。
不调用：`/run`（本机无 iOS 工具链，跑不起 app）、`/refactor-advisor`+`/perf-profiler`（契约 §0 只许碰
9 个文件且明令"不要重新设计"）、`/frontend-design`（Web 向）、`/domain-modeling`（域模型已由契约冻结，
`Design/CONTEXT.md` 不在可碰清单里）。

**基点** `7ab47e61` · 分支 `feat/s3-02-timeline` · 工作树 `C:/Users/Azusa/.zen/worktrees/s3-02`。
执行 `tasks/stage3-20260922/36-s3-02-spec.md`（已过覆盖轮与编排者闸的执行契约）。
合并前基线 **360 tests / 51 suites**。

### 触碰的文件（契约 §0 允许的 9 个；`tasks/**` 只追加）

- [ ] `App/Conversation/ConversationTimeline.swift` —— 新建：纯类型 + `build`/`itemize`（不 import UI/DB）
- [ ] `App/Conversation/ConversationTimelineLoader.swift` —— 新建：读 store，组装纯输入
- [ ] `App/Conversation/ConversationTimelineView.swift` —— 新建：SwiftUI 视图，**不挂载到任何地方**
- [ ] `App/Persistence/PersistenceStore+TimelineReads.swift` —— 新建：`runs(inConversation:)` / `toolResults(forToolCallIDs:)`
- [ ] `Tests/ZenAgentTests/ConversationTimelineProjectionTests.swift` —— 新建：契约 §6.1 的 13 条
- [ ] `Tests/ZenAgentTests/ConversationTimelineLoaderTests.swift` —— 新建：契约 §6.2 的 5 条
- [ ] `Tests/ZenAgentTests/ConversationTypographyDisciplineTests.swift` —— 新建：契约 §6.3 的 3 条静态关卡
- [ ] `Tests/ZenAgentTests/PersistenceFixtures.swift` —— **只追加带默认值的参数**（`endReason` / `createdAt` / `updatedAt`）
- [ ] `AGENTS.md` —— §8 Layout 补 `App/Conversation/` 一行

**不碰**：`project.yml`（`sources: - path: App` 是全目录声明，新文件自动进 target）、`.github/workflows/ci.yml`、
`Config/*.xcconfig`、`Resources/**`、`App/ZenAgentApp.swift`、任何既有测试的断言、依赖、色板。

### 已核对的仓库事实（写码前逐条查过，避免照抄契约里的错名）

- `PersistenceStore` 是 `struct: Sendable`，存储属性名 **`database`**（`ZenDatabase`，final class）✓
- `AgentRunRecord` 有 `kind/state/endReason/triggerMessageID/responseMessageID/createdAt/activeSlot` ✓
- `PersistenceStore.decodeTextPayload` / `ToolCallPartPayload` / `ToolResultPartPayload` 均在 app module 内可 `@testable` 访问 ✓
- `Typography.font(for:dynamicTypeSize:)` 与 `.conversationPrompt/.conversationBody/.interfaceCaption/.codeInline/.codeBlock` 存在（S3-01 产物）✓
- `activeSlot` 只在 `kind == .parent && state.isActive` 时非空 → 同会话多 parent run 只能靠**终态**共存 ✓
- `Fixtures.run` 目前硬编码 `endReason: nil` / `createdAt: epoch` → 断序与失败用例需要追加默认值参数 ✓
- `Fixtures.send` 不能设 `createdAt` → 断序用例里用 fixtures 记录 + 真 `SendCommit` 组装（不手搓 record）✓
- 无 `Fixtures.toolResult`，但既有测试（`ToolRuntimeTests.swift:33`）就是在测试里直接构造 `ToolResultRecord` → 沿用该既有惯例，
  不新增 fixture 函数 ✓

### 本地静态校验（本机唯一验证手段）

- [ ] CI hygiene 等价 grep：`App/Conversation/**` 不含 `import GRDB`；新文件都在允许目录内
- [ ] 契约 §6.3 的三条静态断言在本地用等价 shell 复算一遍（找根/规范化/子串）
- [ ] 注释里不出现被禁写的字体写法（规范化后是子串匹配，注释同样会命中）
- [ ] **未编译**：本机无 Swift/Xcode，Swift 一行都没过编译器。CI 是唯一判据。

### 执行结果（实现提交 `805e5e9`；验收见回执）

- [x] 9 个文件全部落盘，`git status --short` 没有第 10 个文件；`tasks/**` 只追加（`git diff --numstat` = `48 0`，
      随后本节再追加一次，仍无删除）
- [x] 本地静态校验（本机唯一手段）：契约 §6.3 的等价复算通过——`App/Conversation/` 3 个源文件、
      去空白后不含三种禁用写法、8 处字体全部走 `Typography.font(for:`
- [x] CI hygiene 等价 grep：`App/Conversation/**` 不含 `import GRDB`；新文件全部在允许目录内
- [x] 两份独立审查（编译风险 / 契约逐条）：无编译错误；§6.1 的 13 条、§6.2 的 5 条、§6.3 的 3 条逐条有对应用例、无空洞断言
- [ ] **未编译**：本机无 Swift/Xcode，Swift 一行都没过编译器；行为正确性只能由 CI 回答

### 契约与仓库的两处张力（按契约执行，在此记账，未自行改动）

1. §2 的 `runs(inConversation:)` 用 `AgentRunRecord.filter(...).fetchAll(db)`；而 `activeParentRuns(inConversation:)`
   （`App/Persistence/PersistenceStore.swift:406`）刻意逐行走 `Row` + `decodeRun`，其注释（同文件 `:349` 起）写明
   目的是「the storage-engine's vocabulary never reaches the Runtime or the UI」。按契约字面落盘的代价是：
   某行 `requestConfigSeed` 读不出时，时间线读会以 **GRDB 原始错误**抛出，而不是
   `PersistenceError.unreadableRequestConfigSeed`。这属于「契约要求 X，仓库既有做法是 Y」，交规划者定夺。
2. §6.2 要求「不要手搓 record」，但 §0 第 8 条只许给 `PersistenceFixtures.swift` **追加带默认值的参数**，
   而 Fixtures 里没有 `toolResult` 构造器。两条不能同时满足：按 §0（更硬的边界）执行，在测试里直接构造
   `ToolResultRecord`——与 `Tests/ZenAgentTests/ToolRuntimeTests.swift:33` 的既有惯例一致。

### 契约未规定处的判断（偏离已列，理由已给）

- 间距常量额外走 `@ScaledMetric`：契约只要求「具名常量 + 注明需真机校准」，这里让间距随 Dynamic Type 缩放。
- 静态关卡比 §6.3 多一条：删掉 `.font(Typography.font(` 后不得再有 `.font(`——禁掉 `.font(.body)` 这类
  绕过 token 的写法（§5「所有文本必须走 token」）。加上后 8 处调用全部通过。
- §5「reasoning / 工具活动默认折叠」与同句「不做交互动作」冲突。取最小读法：单行截断、无展开手势，
  不新增交互；若规划者要的是「可展开」，那是一处行为变更。
- 工具 `state` 与运行 `state`/`endReason` 直接显示枚举 rawValue：不发明用户可见文案（文案表与 Retry 入口属于第 7 项）。
- 用户 Capsule 的底色用契约 §5 给出的 `Color(.secondarySystemBackground)`（系统语义色），未自建色板。

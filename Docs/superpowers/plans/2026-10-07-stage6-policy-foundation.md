# Zen Agent — Stage 6 并行工作树实施方案

> **For agentic workers:** REQUIRED SUB-SKILL: 使用 `superpowers:executing-plans` 或 `superpowers:subagent-driven-development` 按任务执行。新会话只执行本文 S6-01；S6-02 及以后是路线图，不属于本次自动连续执行范围。

**Goal:** 在不干扰 Stage 5 收口的前提下，交付可独立测试、尚未接入生产 dispatch 的 Tool Policy 规则内核。

**Architecture:** 复用既有 ToolRegistry、ToolExecutionIntent、ToolRuntime 与 ToolCall 持久化链路。先新增纯值类型、scope 匹配和纯策略求值；Stage 5 收口后，再把规则接入原有调用链。不得另造 Registry、Executor、ToolCall 状态机或文件仓库。

**Tech Stack:** iOS 26、Swift 6 complete strict concurrency、Swift Testing/XCTest、GRDB、XcodeGen、GitHub Actions macOS CI。Windows 只进行可实际执行的静态检查，不声称本机完成 Xcode 编译。

**Spec:** Blueprint 的 `Design/Zen Agent 开发规划.md`、`Design/Zen Agent Tool Runtime.md`、`Design/Zen Agent 安全与权限.md`、`Design/CONTEXT.md`。开发规划核对到反馈提交 `3b4b22c0df91be668406127c84c1822b359883c0`；Tool Runtime 在该反馈线与 baseline `99d30b815651fe987bab9f88e269a84a89318625` 间没有修改。

## 0. 本次审查事实与授权边界

审查日期：2026-10-07。本文件是静态代码审查与开发方案，未执行 Swift 编译、行为测试或真机验收。

| 项目 | 本次核对结果 |
| --- | --- |
| 生产仓库 | `54zhien/Zen-Agent` |
| 当前收口分支 | `codex/s5-handoff-repairs-20261007` |
| 本方案固定源码基点 | `0c1122592b4112f136063e228c5d3376a8707853` |
| 对应 source tree | `29ef04ccaf94cbbd439fce4d0f87860b0a11b740` |
| 核查到的 CI | run `37619427383`，`in_progress`；不计为 GREEN |
| `main` | `eec3eb38c3d4869a58031449f303f04dec55d0fd`，不是当前累计 Stage 5 源码 |
| 与此前 `1de29d35f69a45f4420907b494805cece87e7853` 比较 | 新增 6 个提交，已经出现实际生产与测试改动；不再仅是计划文档 |

当前四项收口的代码状态必须分别记录：

- Sidebar New 已出现 `rememberCurrentSession(retainUncommitted: true)` 修复；不能仅凭源码把回归测试标为通过。
- 账户提交后已出现 retained Session 可用性刷新、generation 和 owner/configuration 防过期检查；本轮 CI 尚未完成。
- `currentSettingsNewID` 仍只接受 `conversationLifecycle == nil`；已有持久记录的空会话仍被正式 Configure 入口排除。
- `openInSplit` 失败仍写 `splitOpenError`；最近会话 Sheet 读取 `recentLoadError/recentOpenFailure`，错误交接尚未统一。

因此，本次新工作树仅是**隔离的 S6-01 准备性开发**。旧工作树继续完成四项修复、整合候选 CI 和交接。不能宣称 Stage 5 已关闭，不能因为某一轮 CI 通过就自动进入完整 Stage 6。真机验收继续单独记账，不由代码 CI 代替。

## 1. 工作树与集成方式

### 1.1 创建前检查

先检查 Codex 会话实际绑定目录、`git worktree list`、当前分支与工作树状态。有平台已创建的隔离工作树时优先使用，并核对其基点；不要在其中无意义地再套一层工作树。

若需手工创建，以下命令在**已有 Zen-Agent 仓库目录**运行。不会切换旧工作树的分支。目标目录与分支必须尚不存在；存在时读取并核对，不使用 `-B` 或 `--force` 覆盖。

```sh
git status --short --branch
git worktree list
git fetch origin
git show -s --format="%H %T" 0c1122592b4112f136063e228c5d3376a8707853
git worktree add -b codex/s6-01-tool-policy ../Zen-Agent-s6-policy 0c1122592b4112f136063e228c5d3376a8707853
git -C ../Zen-Agent-s6-policy status --short --branch
git -C ../Zen-Agent-s6-policy rev-parse HEAD
```

新 Codex 会话只绑定新目录。禁止修改旧会话的目录、分支、索引或未提交文件。

若本地与远端 SHA 不同，先比较 source tree，并登记两种提交身份；不能把“tree 相同”写成“同一 SHA”，更不能为了对齐而 reset/rebase 原工作树。若基点对象不可读，停止创建并报告，不擅自退回 `main`。

### 1.2 所有权

| 工作树 | 责任 | 禁区 |
| --- | --- | --- |
| 旧 S5 工作树 | 四项入口修复、原生回归、Stage 5 收口记录 | 不兼做 Stage 6 |
| 新 S6-01 工作树 | 本文限定的 Policy 纯规则与单元测试 | 不修 S5 入口、不接生产 dispatch、不做 Files Tool/UI |

新工作树不得修改以下共享高风险区域：`App/AppShell/`、`App/Workspace/`、`App/Conversation/`、`App/Settings/`、`App/Runtime/`、`App/Persistence/`、`App/Files/`、`.github/`、`Config/`、`project.yml`、`Resources/`、现有共享 handoff/todo 文档。

S6-01 也不修改现有 `App/Tool/ToolRegistry.swift`、`App/Tool/ToolRuntime.swift` 和三项 Built-in 的生产行为；这些内容只作为只读上下文。每个工作树使用自己的测试临时目录，不共享可变测试数据库或构建产物。

### 1.3 集成顺序

S6-01 从固定基点分叉，不追随每次 S5 push 自动 rebase。开发期间出现基线失败，先区分继承的 S5 问题与本分支新增问题；不得顺手修旧工作树负责的文件。

S5 完成四项修复、明确累计候选、完成对应代码 gate，并完成所需的阶段转换确认后，才在**新工作树**吸收固定的 S5 最终提交。优先使用一次普通 merge 保留历史；在双方未暂停工作、未检查 ancestry 前，不自动 rebase、不 force-push。merge 前确保新工作树已提交且干净，冲突必须按文件责任审查。

若 S5 最终以 squash/重写历史进入主线，不直接假设原 stacked ancestry 仍成立。可从经核对的最终基线重新建 S6 集成分支，只 cherry-pick 本方案独立的 S6 提交；原分支保留，禁止连带搬入整段旧 S5 历史。

新 PR 的 base 应指向双方确认的 S5 集成线，或在 S5 入主线后指向主线。不要把包含整段未合并 Stage 5 的 diff 误报成 S6 自身改动。本方案不授权合并 PR、推 main 或打 IPA。

## 2. 代码审查对架构方案的约束

### 2.1 已经存在的机制必须复用

`ToolRegistry.swift` 已定义 ToolDescriptor、ToolExecutable、ToolExecutionIntent（formatVersion 1），以及 target/destination identity 和 approvalDisclosure。`ToolRuntime.complete` 已先 prepare、编码并保存 intent；`executePrepared` 已解码同一记录、核对 descriptor revision，并在 executor 调用前持久化 dispatched。

`PersistenceStore+ToolCalls.swift` 已区分 approved、prepared、dispatched、notExecuted 和 indeterminate 等状态，并提供条件更新。Stage 6 是扩展权限语义，不是重写这条恢复链。

### 2.2 现有能力不等于完整 Policy

当前 descriptor 主要用 `sideEffect` 和 `approvalRequirement` 决定路径，未表达完整 Action/Scope/风险/外发规则。执行前现有 revision 检查不等于当前 Policy、scoped grant、系统权限与稳定目标的全量复核。

这些是 Stage 6 的计划内缺口，不能一概当作 Stage 5 回归缺陷。

### 2.3 Files 必须复用受管字节

`ManagedFileStore` 已有 immutable digest-addressed bytes、FileAsset/version/fingerprint、受保护读取、引用保护删除及进程级共享 operation lock。Files Tool 不得另建存储目录或第二把相互独立的锁。

后续读取要在既有受保护操作内消费字节，不能先拿 URL、释放保护，再任意读取。不能把模型参数中的绝对路径直接传入现有 import API。`ingest` 创建新 asset；后续 modify 必须有明确的新版本发布语义，不能把“再导入一个文件”当作修改原 asset，更不能原地覆写旧 blob。

### 2.4 开放 Files 前要补齐结果边界

现有 ToolRuntime 会直接保存 `executionResult.content`，错误路径还会把 `String(describing: error)` 拼入结果。新增可访问用户内容或外部服务的 Tool 前，必须增加稳定错误分类、Secret redaction、类型与 UTF-8 byte budget 检查，且先处理再持久化/回模型。

取消已区别 dispatch 前后；但对未来外部写的 timeout/断网等错误，不能沿用“一律 failed，因此可重试”的推断。必须有 typed outcomeUnknown/indeterminate 语义；禁止解析自然语言错误字符串做状态决策。

## 3. Global Constraints

- 本轮只执行 S6-01；它是准备性并行开发，不修改当前用户可见行为或权限状态。
- 不另建 ToolExecutionIntent、ToolCall、Registry、Runtime、FileStore；不建立第二份 execution state。
- Policy 必须只有一个计算边界。UI 只能展示/提交决策，不能重算或越过规则。
- Deny 和硬 Safety Cap 不得被临时 grant 绕过。
- allowOnce 绑定稳定 ToolCall、Run、Action、intent binding；终态后不能授权新调用。
- allowConversation 有 subject、tool/action、revision 和明确 scope；本轮只支持精确范围，不提供 wildcard。
- “没有资源要求”与“缺失必要资源身份”是不同值；nil/空字符串不能表示全部资源。
- Settings 收紧影响尚未 dispatch 的旧调用；Settings 放宽不能自动释放旧 waiting 调用。显式审批是另一种输入。
- Grant 的显示位置不是授权主体；不同 Conversation/Run 不得相互借用授权。不实现 Child/MCP/Memory/Skills 来预支后续 Stage。
- Policy 的 allow 只是本次计算结果，不是可永久缓存的执行许可证。
- 不添加依赖、不修改 CI、不开新权限弹窗、不增加 entitlement 或系统能力。
- GRDB 继续仅在 Persistence；Security 继续仅在 Credential；网络与 Credential 不进入纯 Policy 内核。
- 新生产值类型满足 Sendable；不为方便新增 `@unchecked Sendable`、锁、全局可变单例。

## 4. S6-01：当前允许执行的详细任务

以下接口名称是**拟新增设计**，不是声称仓库已经存在。输入只保存策略计算所需的只读事实，不保存第二份 arguments JSON、ToolCall state 或 executor payload。未来接线时由既有冻结 intent 与 Runtime 身份构造，不能由模型自行声明授权事实。

### 文件边界

| 文件 | 责任 |
| --- | --- |
| Create `App/Tool/Policy/ToolPolicyTypes.swift` | Action 风险/授权限制、subject/scope、grant、policy snapshot、求值输入输出的纯值类型 |
| Create `App/Tool/Policy/ToolGrantScopeMatcher.swift` | 精确比较 subject、resource、destination 和必要 revision；不做 I/O |
| Create `App/Tool/Policy/ToolPolicyEvaluator.swift` | 单一纯求值函数；无缓存、无落库、无执行 |
| Create `Tests/ZenAgentTests/ToolPolicyScopeTests.swift` | 范围与主体隔离行为测试 |
| Create `Tests/ZenAgentTests/ToolPolicyEvaluatorTests.swift` | Deny/Cap/Policy/grant 优先级测试 |
| Create `Tests/ZenAgentTests/ToolPolicyTemporalTests.swift` | 收紧/放宽、撤销、终态及过期上下文测试 |
| Create `Docs/superpowers/plans/2026-10-07-stage6-policy-foundation.md` | 本计划或落地后的工程细化，只记录本分支 |
| Create `tasks/s6-01-tool-policy.md` | 基点、diff、RED/GREEN、限制和交接；不改共享 todo/handoff |

项目已经按 `App` 与 `Tests/ZenAgentTests` 目录收集源文件；本轮新增文件无需修改生成工程或 project.yml。

### Task 1：精确 Scope 与主体匹配

**Consumes:** 已有身份类型和蓝图权限语义，仅只读参考。

**Produces:** `ToolGrantScopeMatcher.matches(grant: ToolScopedGrant, call: ToolPolicyCallContext) -> Bool`，及其真正使用的纯值类型。

约束输入：

- Call context 包含稳定 ToolCallID、agentRunID、授权主体、toolID、actionID、descriptor revision、冻结 intent binding，以及实际 resource/destination scope。
- Grant 包含授权粒度、同样的身份绑定、scope、有效/撤销状态。allowOnce 还必须匹配原 call 与 run；allowConversation 不匹配任意别的主体。
- Scope 必须显式区分不需要资源的 Action 和精确范围；对 Files 精确身份使用 asset/version/content identity，对外发使用真实 Provider instance/endpoint identity。不可把模型声称的 destination 当权威。
- 不在本任务写 URL 规范化、任意路径解析或跨系统 resolver。只消费已解析的稳定身份；这些可信投影在后续 Runtime 接线时建立。

- [ ] 写可编译的行为测试：`sameExactScopeMatches`、`missingScopeIsNotWildcard`、`differentResourceDoesNotMatch`、`differentFileVersionDoesNotMatch`、`differentDestinationDoesNotMatch`、`differentSubjectDoesNotMatch`、`differentActionDoesNotMatch`、`descriptorRevisionChangeInvalidatesGrant`。
- [ ] 覆盖同 endpoint 不同 Provider instance、同展示名不同 asset、缺少 Files 必需 version/fingerprint 的拒绝；scope-less Action 只能匹配同样明确无资源要求的调用。
- [ ] 按第 5 节取得有效 RED；新增 API 的“不存在/编译失败”不是行为 RED。
- [ ] 实现精确匹配，不写任何 wildcard fallback 或隐式 scope 扩大。
- [ ] 取得此组测试 GREEN，检查没有接入生产路径；按明确文件清单提交，禁止 `git add .`。

### Task 2：单一 Effective Policy 求值

**Consumes:** Task 1 的 context、grant 与 scope matcher。

**Produces:** `ToolPolicyEvaluator.evaluate(_ input: ToolPolicyEvaluationInput) -> ToolPolicyDecision`。

输入包括 Action 元数据、当前硬限制、调用创建时 Policy/admission、当前 Policy、当前调用上下文、scoped grants。长期 Policy 表达 alwaysAllow/askEveryTime/deny；Action 元数据独立声明是否允许长期自动批准、是否允许 conversation grant、scope/egress 的要求。未知或缺少必需元数据不能自动允许。

输出必须是带稳定 reason code 的 allow / needsApproval / deny / dependencyChanged（或等价枚举），不能靠中文/英文提示字符串判断业务状态。它不更新 ToolCall，不生成审批、不调用 executor。

求值规则：

1. 无效身份/缺失必需范围/descriptor 或目标语义变化，不能沿用旧授权。
2. 硬 Deny、当前 global deny 优先；grant 无法覆盖。
3. 高风险 Action 的“必须显式确认”和“不可长期自动允许”是 Policy 输入，不能仅供 UI 展示。
4. 当前 Policy 为 askEveryTime 时，只有当前主体、调用和范围适用的显式 grant 才能满足确认；错误范围的 grant 不授予任何额外权限。
5. alwaysAllow 仅在 Action/Cap/scope/egress 均允许时自动通过，不意味着越过高层限制。
6. allowConversation 不适用于声明禁止该粒度的 Action；不偷换成 allowOnce。用户需作出实际允许的选择。

- [ ] 写 `hardDenyOverridesOnceAndConversationGrants`、`globalDenyOverridesEveryGrant`、`explicitApprovalCapBlocksAlwaysAllow`、`matchingOnceSatisfiesAskPolicy`、`matchingConversationGrantIsScopeBounded`、`destructiveActionCannotUseForbiddenGrantKind`、`unknownMetadataDoesNotAllow`。
- [ ] 对 global deny × 两种 grant、cap × alwaysAllow、askEveryTime × scope mismatch 做参数化矩阵。测试 scope mismatch 时明确其他输入没有独立许可，避免把 global allow 与 grant 匹配混为一谈。
- [ ] 取得 RED 后实现最小求值函数；相同输入必须产生相同输出，不能读取 Date()、UserDefaults、数据库或网络。
- [ ] 取得 GREEN 并提交；不要为了让测试通过向 AppAssembly 注入新对象。

### Task 3：时间语义与失效规则

**Consumes:** Task 2 evaluator 与同一组值类型。

**Produces:** 仍是同一个 evaluator；不增加“旧调用策略引擎”。

调用创建时的 admission 和当前 Policy 必须分别可表达。撤销/政策代际的事实由未来持久层提供；本阶段用显式输入验证规则，不能通过 UI 是否仍显示 Sheet 推断权限。

- [ ] `tighteningRevokesUndispatchedAllowance`：原本允许但当前 global deny，结果必须 deny。
- [ ] `settingsWideningDoesNotReleaseWaitingCall`：原 waiting/needsApproval 的调用遇到 Settings ask→alwaysAllow，没有明确当前调用审批时仍不能直接执行。
- [ ] `explicitApprovalCanAuthorizeOriginalWaitingCall`：当前规则允许且用户给出匹配的新 allowOnce 后，同一调用才允许。
- [ ] `onceCannotAuthorizeAnotherCallOrRun`、`onceIsUnavailableAfterTerminal`：同 tool/action/参数也不能复用到下一次调用。
- [ ] `revokedConversationGrantDoesNotReturnAfterPolicyWidening`：收紧导致失效的旧 grant，后来放宽不能自动复活。
- [ ] `approvalDisplayOwnerDoesNotChangeGrantSubject`：展示在某 Pane 不改变 subject，不同主体仍不匹配。
- [ ] `destinationOrVersionChangeCannotReuseApproval`：旧许可不能对应到新 Provider destination 或新文件内容。
- [ ] 取得有效 RED/GREEN，提交后停在第 6 节交接状态，不自行开始 S6-02。

## 5. CI 与测试策略

当前 workflow 的 concurrency group 是 `ci-${{ github.workflow }}-${{ github.ref }}`。新分支的 push 不会因为这个 group 取消旧分支的 push；但工作树不隔离仓库的 Actions 资源和运行额度。

现有 `stage5_test_profile.py` 对非 `codex/s5-` 分支返回 `full`。新 S6 分支不能假定只跑本轮新单测，也不得自行改脚本、增加临时 profile、跳过 UI 或缩小最终 gate。

每个任务先写行为断言。对于全新 API，必要的签名/保守 stub 可以与测试一起提交以形成可编译 RED；例如默认拒绝的 stub，再由正向用例证明功能尚未实现。缺少类型、编译失败、fixture 崩溃不能标作行为 RED。不得为表现 RED 改动已上线权限行为。

Windows 实际执行：

```sh
git diff --check
git status --short --branch
git diff --name-only 0c1122592b4112f136063e228c5d3376a8707853...HEAD
```

检查未追踪文件列表与完整变更清单；三点 diff 不包含未提交文件，不能只看它判定没有越界。

macOS/CI 定向诊断命令参考，UDID 必须来自真实可用 Simulator：

```sh
xcodegen generate
xcodebuild test -project ZenAgent.xcodeproj -scheme ZenAgent \
  -configuration Debug -destination "id=$UDID" \
  -only-testing:ZenAgentTests/ToolPolicyScopeTests \
  -only-testing:ZenAgentTests/ToolPolicyEvaluatorTests \
  -only-testing:ZenAgentTests/ToolPolicyTemporalTests \
  -resultBundlePath "$RUNNER_TEMP/S6Policy.xcresult"
```

以上定向命令是诊断，不替换仓库的全量 workflow。保留既有 ToolRegistryTests、ToolRuntimeTests、ToolRuntimeRecoveryTests、ToolDispatchRecoveryTests、MultiToolBatchTests、ToolRejectionContinuationTests、Stage2GateTests 等回归。

分支 code gate 记录实际测试报告中的数量、失败、skip、host restart；不抄历史测试总数。S5 整合后必须对**最终组合 SHA/tree**再跑完整 CI，不能把两个分支各自的 GREEN 拼成整合 GREEN。纯规则 CI 通过也不代表 Files Tool 或系统权限已完成。

## 6. 本次停止点与交接清单

仅在 S6-01 的实际代码/测试/记录完成后交接，报告：

- 新工作树路径、分支、初始基点 SHA/tree、最终 SHA/tree。
- 精确修改文件清单；确认没有触碰旧工作树和共享高风险区域。
- 每组 RED/GREEN 的真实 run、测试名、失败原因与结果；缺失项如实标记未验证。
- 全量 CI 状态和基线继承失败，不能把 cancelled/skipped/in_progress 当 passed。
- 规则测试覆盖的边界，和明确未实现的生产接线、持久化、系统权限、Files、Settings。

**做到这里就停。不得自动开始 S6-02，不合并、不推 main、不打 IPA、不声称 Stage 6 完成。**

## 7. Stage 6 后续路线图（本方案建议编号，不是现有完成状态）

### S6-02：Action 元数据与版本化冻结意图

前置：S5 收口完成且阶段转换得到确认。

把 S6-01 的 Action 元数据接入原 ToolDescriptor，不建立并行 registry。沿现有 ToolExecutable.prepare 执行参数校验、Action 解析和目标规范化；校验失败必须形成稳定结果，不能让一项非法 Tool Call 丢失整批 continuation。

扩展既有 ToolExecutionIntent/codec，而不是新增另一种可执行载荷。新增 schema/format 需要明确版本化；不能只增加非 optional Codable 字段导致旧数据无法解码，也不能给旧 intent 填默认“允许”范围。

测试既有 v1 记录的终态展示与结果复用、旧 pending intent 的显式兼容/拒绝路径、未知新版本的安全处理、descriptor 变化、目标变化、损坏 JSON。旧 pending 不能直接提升成新授权；仅在明确证明语义等价的兼容路径上继续，否则在原 ToolCall 上重审或形成明确结果，不重新造 call ID。

此步才设计必要的 Persistence API/迁移，并复核现有对 executionIntent 更新与状态迁移的约束。

### S6-03：Policy / grant 持久化

在 `App/Persistence/` 内增加所需记录与事务接口；Policy 计算仍留在唯一内核。global policy 与 scoped grant 不混表意图、不混生命周期。grant 绑定 subject/action/revision/scope，明确撤销、政策收紧失效、主体结束失效和 allowOnce 消费语义。

测试恢复、并发授权/撤销、同 Tool 不同主体、不同 endpoint、不同文件版本、Policy 收紧后重新放宽不复活旧 grant。Grant 不得因为从哪个 Pane 点了按钮而归错主体。

### S6-04：原 Runtime 接线与交互状态

接入现有 ToolRuntime、审批投影与恢复链。统一普通执行、approve 后执行、prepared/approved recovery 的 dispatch 前复核；不能只在 UI 点击 approve 时检查一次。

复核当前 Policy/Cap/grant、descriptor revision、稳定 target 与实际系统权限。对可控制的 Policy/dispatch 状态，用明确串行化或版本条件更新处理“校验后撤销”窗口，不能先 await 多项检查再盲目落 dispatched。OS 状态仍需实际 preflight/执行失败处理，不能声称本地锁使外部权限不存在竞态。

系统 notDetermined 与 Tool approval 分开：先进入 waitingForSystemPermissionConsent，只有明确用户操作才请求系统权限；该操作不自动发 grant。没有真实实现的系统能力保持不可用，不添加无关 Calendar/麦克风 Tool 或伪造已授权。注入状态测试不代替真实系统权限验收。

保持 dispatched-before-executor、原 call identity、notExecuted/indeterminate、不盲目重放外部写；补 typed dependencyChanged/reapprovalNeeded/outcomeUnknown 的持久结果与 continuation。不要把 ToolCall 错误误写成新增 Run EndReason。

### S6-05：Files.read 最小闭环 + egress / result guard

模型只能提交受管 FileAsset 引用；冻结 asset/version/fingerprint。权限展示与 grant scope 必须包括“读取哪个文件”及“结果将进入哪个实际 Run Provider/endpoint”。Provider destination 取自冻结 execution snapshot，不取当前 Settings。

复用 ManagedFileStore 受保护字节路径，拒绝任意绝对路径、父目录穿越、symlink 逃逸和版本偷换。仅提供有界读取/支持的类型；超大或不支持的结果返回明确 reference/错误，不把整个文件装进内存再裁剪。

在原结果链增加类型、UTF-8 byte budget、Secret redaction 和稳定错误映射。先处理再保存/展示/回 Provider。恶意 Tool 文本始终是不受信任数据，不能成为权限指令。

用户导入 Workspace 不等于 Agent 获得读取 grant；当前明确发送的 attachment ingestion 与模型自主 Files Tool Call 分开，不绕过 global deny，也不扩张成整个 Workspace。

**read、真实 egress 声明、结果处理必须作为一个可发布闭环，不能先放开读文件，后面再补安全。**

### S6-06：Files.create / modify / delete

在 read 链通过后增加写与删除。修改发布新内容版本，保持旧 Message/Run 引用；删除复用持久引用、warm draft、双 Pane 和 pending Send 的保护，不绕开既有共享 lock。

明确处理 ToolCall 与文件发布的崩溃窗口，测试“文件操作可能成功但调用结果未落库”、重复恢复、取消、删除/修改竞争。未经证明的外部/文件写结果必须标不确定，不能自动再次执行。对危险 action 默认提供保守可解释的确认粒度，不能从其他 action 推导权限。

### S6-07：Settings → 可调用工具与全阶段 gate

接入正式 Settings，展示真实 policy、可撤销的 scope、必要的系统状态，不另造临时入口。完成批准→Settings 收紧→返回旧卡片→拒绝 dispatch 的原生回归，以及 Provider endpoint/文件内容变化后旧授权失效的回归。

最终 gate：Deny/Cap 无法被任何 grant 绕过；审批内容等于实际执行意图；旧宽泛授权不能组合成任意 source→sink 外发；终态/恢复/并发正确；完整最终源码 CI 与实际需要的真机验收分别记录。

Stage 7 Memory、Stage 8 Skills、Stage 9 MCP、Stage 10 Subagent 不属于本轮或此路线图的提前实现内容。

## 8. 证据定位

以下路径均按本方案记录的固定 SHA 核对；源码行号可能在后续提交移动，应以 SHA 和符号定位。

- `App/AppShell/AppShellModel.swift`：currentSettingsNewID、refreshSendAvailability、newConversation、openInSplit。
- `App/AppShell/NewConversationView.swift`：最近会话 Sheet 的 recentLoadError/recentOpenFailure，Sidebar Configure 可见性。
- `App/Tool/ToolRegistry.swift`：既有 descriptor/intent/prepare/execute 协议。
- `App/Tool/ToolRuntime.swift`：complete、executeApproved、executePrepared、encode/decode、result/error 持久化。
- `App/Persistence/PersistenceStore+ToolCalls.swift`：ToolCall 状态条件更新与 dispatch checkpoint。
- `App/Files/ManagedFileStore.swift`：version/fingerprint、withVerifiedBlob、operationLock、removeUnreferencedAsset、ingest。
- `Tests/ZenAgentTests/ToolRegistryTests.swift`：三项 Built-in 与 descriptor/intent 行为。
- `.github/workflows/ci.yml`、`.github/scripts/stage5_test_profile.py`、`project.yml`：分支 concurrency、默认完整 profile、目录化 sources。
- `Docs/superpowers/plans/2026-10-07-stage5-handoff-repairs.md`：当前四项 S5 修复边界与后续未完成项。
- Blueprint `Design/Zen Agent Tool Runtime.md`：Action/Policy、Grant Subject、时间语义、冻结 intent、Files、source→sink 和 result 边界。
- Blueprint `Design/Zen Agent 开发规划.md`：Stage 6 范围与 gate。


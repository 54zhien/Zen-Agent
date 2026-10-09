# Stage 5 入口交接修复计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking. 用户已确认执行；后两项已获委派授权，按串行行为 RED→完整 CI GREEN 执行。

**Goal:** 修复 Sidebar New、账户重认证、持久空会话 Configure 和副 Pane 最近会话打开失败四条交接路径。

**Architecture:** 保留 Session Store 的草稿保护、Persistence 的事务初始化、Runtime 的冻结请求和 Router 的准备票据。统一入口需要的决策与操作结果，不做全局 AppShell 重构。

**Tech Stack:** iOS 26.0、Swift 6.0 / complete strict concurrency、SwiftUI/UIKit、GRDB、XcodeGen、Swift Testing/XCTest、GitHub Actions macOS CI。

**Spec:** 用户附件 `C:/Users/Azusa/.codex/attachments/2793db1b-38b6-4238-b50c-369515642a62/已粘贴的文本.txt`；Blueprint `Design/Zen Agent 开发规划.md`、`Design/CONTEXT.md`、`Design/Zen Agent App Space、Split 与全局导航.md`。本地 Blueprint：`C:/Users/Azusa/Desktop/Zen Agent`。

## 复核基线与证据

- 复核日期：2026-10-07。本轮没有运行 Xcode、行为回归或实机测试；下面是静态调用链结论，需执行阶段以 RED 验证。
- 生产远端分支 `codex/zen-liquid-icon-20261006`：`900071066f8b30df3895b0390e8d637bb7eae647`，tree `26ba71ddc08c3f90b6e400b973e22f549768d1e4`。
- 本地工作树 `C:/Users/Azusa/.codex/worktrees/s5-history-handoff/Zen-Agent`：`d764cafffb4a0fc19b010163d2a8e75399715862`，tree 与上项完全相同。提交身份不同，不可将其记为同一 SHA。
- 桌面生产 checkout 在 `main` / `eec3eb38c3d4869a58031449f303f04dec55d0fd`，不作为四项修复的源码起点。
- Blueprint 本地 `62bd26bffe7cace580d1631dfee87318d4fe3a9d`，远端反馈分支 `3b4b22c0df91be668406127c84c1822b359883c0`；tree 同为 `44d1101259b94bb56626e9c04e03ba65da3e5fc6`。
- PR #34 当前 draft/open/unmerged，head `fd8655999fef4758db947fb734f50e7c6bde24b8`。其完整 CI `37348331672` 三个 job 成功；图标提交专项 `37362906396` 成功，完整 CI `37362906450` cancelled。本轮未重新核算历史测试数量。
- `AppShellModel.newConversation()` 单栏路径调用默认不保留未提交状态的 `rememberCurrentSession()`；无数据库摘要时会移除 Session。Split replacement 与 App Space New 已使用保留路径。
- Settings 账户保存回调只重新加载 catalog，关闭 overlay 只失效 Settings 并恢复焦点；原 Composer 的 availability 不刷新。`ConversationPaneFactory.makePane` 已会重校验，因此问题限定于没有重新构建 Pane 的路径。
- `currentSettingsNewID` 排除一切已有持久记录；Sidebar 与 overlay 都依赖它。旧 `targetWasSaved` 已调用事务初始化，`unconfiguredNewCanBeExplicitlyConfigured` 也覆盖旧 providerSetup 入口，但正式 Settings 回调没有接上该持久配置路径。
- 副 Pane `openInSplit` 失败写 `splitOpenError`，最近列表消费 `recentOpenFailure/recentLoadError`。已占用副 Pane 不显示空 Picker，因此失败消息不可达。

## Global Constraints

- 四项按顺序独立完成，每项都先取得行为 RED，再写生产修复，再取得真实 CI GREEN。
- 不合并 PR、不推 main、不打 IPA、不进入 Stage 6。最终停在可 review 的修复分支和证据记录。
- 不添加 Draft 持久化、数据库迁移、Provider 能力、文件发送、工具开关、依赖或字体/图标改动。
- 全局默认仅用于未来 New；不能覆盖现有 Session 模型选择、旧 request seed、execution snapshot 或 credential binding。
- 不修改生成的 `.xcodeproj`。平台与 Swift 设置仍唯一声明在 `Config/*.xcconfig`。
- Secret 不入仓库、fixture、日志；测试使用仓库已有假凭据模式，不使用真实 Key。
- Blueprint 定义意图。当前四项是入口遗漏，未发现需要改变设计或记录 ADR 的冲突；执行中新发现冲突时按 AGENTS.md 的事实核查流程处理。
- 先检查聊天附件/worktree 注册与工作树状态；优先使用适合的已附工作树。需要隔离时从远端 `9000710` 建 `codex/s5-handoff-repairs-20261007`，不从旧 main 开始。保留已有 `__pycache__`、AGENTS.md 和所有无关产物。

## Review Focus

- 未发送的中文/emoji 草稿、非零 UTF-16 选区、Quote/Attachment、会话配置与 pending submission 必须仍属于原 Session；任务 1 覆盖。
- 账户更新成功而模型不支持、凭据仍不可读时不能变成 ready；任务 2 覆盖。
- 重认证与会话切换、Settings 关闭交错，旧结果不能更新新的 owner；任务 2、3 覆盖。
- Configure 与首次 Send、删除或第二次 Configure 竞争，事务拒绝后不能只更新 UI 配置；任务 3 覆盖。
- 副 Pane 已占用、请求取消/过期、目标读取失败与列表分页失败必须区分；任务 4 覆盖。

## 共同执行与 CI 节奏

以下步骤每个任务各执行一次，不跨任务混合 RED 与修复：

- [x] 增加该任务行为测试；确保断言在当前生产源码可编译，且失败原因是所审缺陷，不能把编译失败或 fixture 失败当 RED。
- [x] 只提交/推送测试及必要的 DEBUG 测试夹具；等待 CI 报出预期行为失败，记录 SHA/tree、run URL、测试名与断言。此时不写生产修复。
- [x] 实施最小修复；本地执行 `git diff --check`，检查 project.yml、路径与 ignore 边界，只 stage 本任务文件。
- [x] 提交/推送 GREEN，等待现有完整 CI（hygiene、XcodeGen、build、unit/UI、独立 iPad axis）和适用的现有 build-settings guard。真实失败先修，不以 cancelled/skipped 替代 passed。
- [x] 记录 GREEN SHA/tree、job、失败/跳过/host restart 状态，完成该任务 review 后再进行下一项。

本轮不改 CI 范围以节省成本。新分支默认使用完整现有流程，避免旧临时 profile 导致漏跑。若执行时另行获准使用定向 RED，其记录必须明确 scope，GREEN 与最终 Gate 仍跑全量。

macOS runner 的定向排错命令采用现有工程 scheme，例如：

```sh
xcodegen generate
xcodebuild test -project ZenAgent.xcodeproj -scheme ZenAgent \
  -configuration Debug -destination "id=$UDID" \
  -only-testing:ZenAgentTests/SidebarNewSessionTests \
  -resultBundlePath "$RUNNER_TEMP/SidebarNewSession.xcresult"
```

`UDID` 必须来自 runner 的可用 Simulator 列表；Windows 不执行该命令，也不能声称已本地 build。其余任务更换 suite 名；UI 另使用对应 `ZenAgentUITests` class。全量 Gate 交由既有 `.github/workflows/ci.yml`。

## Task 1：Sidebar New 保留未提交 Session

**Files:** Modify `App/AppShell/AppShellModel.swift`；Create `Tests/ZenAgentTests/SidebarNewSessionTests.swift`；Modify `Tests/ZenAgentUITests/SidebarUITests.swift`。仅在测试证明现有 demote 策略不足时修改 `App/Conversation/ConversationSessionStore.swift`。

**Interfaces:** 继续消费 `newConversation() -> Void`、`rememberCurrentSession(retainUncommitted:)`、`sessions.retain(_:reconstruction:)` 和现有 App Space browse/return。生产接口不变；Sidebar `.new` 仍调用同一方法。

- [x] 增加 `sidebarNewRetainsUnsentSessionAndRestoresDraft()`：用现有 `AppShellWiringTests.makeFixture(seed: .none)` 创建无 Conversation 记录的 A，设置草稿 `未发送的草稿 🧑🏽‍💻`、`ComposerSelection(range: 1..<3)` 与 configuration；调用真实 Sidebar action；进入 B 的 App Space，找回 A 并 Return。断言如下（`originalDraft` 是完整 `ComposerDraftState` 快照）：

```swift
#expect(shell.conversationID == originalID)
#expect(shell.pane?.session === originalSession)
#expect(shell.pane?.composer.draft == originalDraft)
#expect(shell.pane?.composer.configuration == originalConfiguration)
#expect(try fixture.store.conversationLifecycle(id: originalID) == nil)
```

- [x] UI 增加 `testSidebarNewReturnsToOriginalUnsentDraftThroughAppSpace`：点正式 Sidebar New，不能替换为直接调用 App Space New；确认 Return 后全文、选区可恢复。需要 DEBUG selection probe 时复用原生 interaction probe 风格。
- [x] 补 `sidebarNewRetiresOnlyReconstructibleBlankSession`：真正空白可重建页退役；有配置改动、阅读位置、pending submission 或 runtime protection 的原 owner 不退役。复用 Session Store 已有测试与保护判断。
- [x] 取得共同流程中的行为 RED。
- [x] 单栏 New 显式保留未提交 owner，再由现有 Session Store 激活/demote 决定可重建空页退役。不另建 draft cache，不无条件永久保存所有空页。
- [x] 取得完整 GREEN 并记录证据；复查 Split New、App Space New 与未知/已删除卡片拒绝测试。

## Task 2：账户变更重新校验现有 Session 的发送可用性

**Files:** Modify `App/Settings/ProviderAccountSettingsModel.swift`、`App/Settings/SettingsWorkspaceModel.swift`、`App/AppShell/AppShellModel.swift`、`App/Conversation/ConversationSessionStore.swift`；Create `App/AppShell/AppShellConfiguration.swift`、`Tests/ZenAgentTests/SettingsAvailabilityHandoffTests.swift`；Modify `Tests/ZenAgentUITests/SettingsUITests.swift`。账号页面仍可通过 onSaved 刷 catalog。

**Interfaces（新增）:** 账户 editor 接受 `onCommitted: @MainActor (ProviderInstanceID) -> Void`，仅配置事务/凭据绑定发布成功后触发；由 Settings model 转发到 shell。Session Store 提供只读 `retainedSessions: [ConversationSession]` 快照，包含 active、warm、Preview owner，不引入第二套 owner 表。Shell 提供 `refreshSendAvailability(for instanceID: ProviderInstanceID) async`，放在配置职责文件。

- [x] 增加 `reauthenticationRefreshesRetainedComposerWithoutReplacement`：使原配置因缺 Key 进入 unavailable，保留 Pane/Session 与中文草稿；通过正式 Settings model 的 account editor 保存新凭据并返回，等待刷新。断言：

```swift
#expect(shell.pane === originalPane)
#expect(originalPane.composer.draft == originalDraft)
#expect(originalPane.composer.configuration == originalConfiguration)
#expect(originalPane.composer.sendAvailability.isReady)
#expect(try fixture.store.run(id: oldRunID)?.requestConfigSeed == oldSeed)
```

- [x] 使用已有 fake provider 验证新的 Send 采用新绑定，旧 active Run 的身份/seed/execution snapshot/credential binding 不变；另一 Provider Session 不被改写。
- [x] 增加保存失败、凭据仍不可读、不支持原模型、两 Pane 同 Provider、warm Session、刷新期间切换配置/关闭 Settings 的断言。失败保持 unavailable；迟到结果只能更新仍匹配被捕获 Session 与 configuration 的 owner。
- [x] UI 增加 `testReauthenticationReturnsToSameComposerWithSendEnabled`，走正式保存/关闭路径；草稿与编辑器身份保留，不能通过关闭并重开 Conversation 让测试间接通过。
- [x] 取得共同流程中的行为 RED。
- [x] 刷新以 `AppAssembly.validateTarget` 为依据，在 detached 任务内读取现有 store/credentials/provider，回到 MainActor 后核对 Session 身份、configuration 和操作 generation。无配置继续 unconfigured。成功仅表示本地允许下一次请求，不声明联网认证成功。
- [x] 不替换 Pane、Composer、Run；不改变模型选择。失败消息仍为安全摘要；不要顺带清除 Stop/提交错误等不相关反馈。
- [x] 取得完整 GREEN，复查 SettingsAccount、SettingsScope、历史 credential 与 Run 冻结测试。

## Task 3：正式 Configure 接上持久空会话的一次性绑定

**Files:** Modify `App/AppShell/AppShellConfiguration.swift`、`App/AppShell/AppShellModel.swift`、`App/AppShell/NewConversationView.swift`、`App/Workspace/WorkspaceOverlayCoordinator.swift`、`App/Settings/SettingsWorkspaceModel.swift`、`App/Settings/SettingsProviderViews.swift`；Modify `App/Persistence/PersistenceStore+ConversationMetadata.swift` 以增加只读 eligibility 查询；Create `Tests/ZenAgentTests/PersistedEmptyConfigureTests.swift`；Modify `Tests/ZenAgentUITests/SettingsUITests.swift`。旧事务写入方法保持权威。

**Interfaces（新增）:** Shell 的 `configurationOwner(id: String) throws -> ConversationConfigurationOwner?` 返回 `.uncommitted(id:)` 或 `.persistedEmpty(id:)`；两种都要求匹配当前 Single owner、无 Preview，且没有已有 Composer 配置。Persistence `canInitializeEmptyConversationBinding(id: String) throws -> Bool` 一次 read 检查 visible、零 Message/Run、已有空 binding row。写入仍调用 `initializeEmptyConversationBinding(id:binding:at:) throws -> Bool`，不可依赖之前的只读检查授权写入。

Settings 增加显式 `configureCapturedConversation(providerInstanceID: ProviderInstanceID, modelID: ModelID) async -> Bool`；只在 Configure 模式的已有模型旁显示“用于当前会话”。ProviderSetup 成功也走同一 captured-owner 初始化。普通 `setDefault` 继续只影响未来 New；不把全局默认回调解释成当前会话配置。

- [x] 增加 `persistedEmptyConversationConfiguresThroughFormalSettingsAndSurvivesReopen`：零 Provider → App Space New → Return 已落库空会话 → Sidebar Configure → Settings 添加账户并明确选模型 → 首次 fake Send → 关闭并重新打开数据库/建立新 shell。断言 Configure capability 可达、同 Pane/草稿保留、initial binding 正确、首次 request seed 正确、冷启动恢复使用已提交配置。
- [x] 增加已有账户但无全局默认时的显式配置；选择当前会话目标不自动改全局默认。普通 Settings 改默认不填补任何现有空 binding。
- [x] 增加重复 Configure、配置期间 New/删除/首次 Send、非空历史、已有 copied binding、持久化读写失败。事务返回 false/throw 时 UI 配置保持原状且反馈可见；首次绑定不改变 userActiveAt、Soul binding。
- [x] UI 增加 `testAppSpacePersistedUnconfiguredConversationHasFormalConfigure`，必须从 Sidebar 进入，不调用旧 `providerSetup` 属性。
- [x] 取得共同流程中的行为 RED。
- [x] 所有 Configure 可达性与提交检查消费同一 owner 判定。持久 owner 先事务写成功，后更新其当前 Composer；未落库 owner 只更新 Session。复用现有校验/反馈，去掉重复的默认与显式初始化决策。
- [x] 取得完整 GREEN，保留旧未落库 Configure、stale callback、global-default isolation 与 ConversationMetadata 测试。

## Task 4：最近入口消费带目标身份的打开结果

**Files:** Modify `App/AppShell/AppShellModel.swift`、`App/AppShell/NewConversationView.swift`、`App/Workspace/WorkspaceSurfaceView.swift`；Create `App/AppShell/ConversationOpenOutcome.swift`、`Tests/ZenAgentTests/RecentSplitOpenFeedbackTests.swift`；Modify `Tests/ZenAgentUITests/SidebarUITests.swift`。`AppShellWorkspaceNavigation.swift` 的旧 Bool 调用无需整体迁移。

**Interfaces（新增）:** `ConversationOpenOutcome: Equatable, Sendable` 提供 `.opened(conversationID: String)`、`.cancelled(conversationID: String)`、`.failed(RecentConversationOpenFailure)` 及只读 `isOpened: Bool`；增加 `openConversationResult(id: String) async -> ConversationOpenOutcome` 与 `openInSplitResult(id: String) async -> ConversationOpenOutcome`。原 Bool 方法作为兼容包装，避免本轮改完所有导航调用者。

- [x] 增加 `occupiedSecondaryRecentOpenFailureKeepsPaneAndTargetsRetry`：source=A，secondary=B 已占用；通过 Sidebar Recent 选择 C，注入一次目标 history preparation 读取失败。断言明确 `.failed` 且 target=C、B 的 Pane/Session/草稿不变、最近页面仍打开、C 对应错误和“重试打开”可见；修复读条件后重试打开 C。
- [x] 增加 canceled、被新选择替代、Split arrangement 改变和读任务迟到，不产生错误公告，不覆盖更新操作结果。列表分页失败仍重试分页，目标打开失败重试该 ID。
- [x] UI 增加 `testOccupiedSecondaryRecentFailureIsVisibleAndRetryable`，必须让副 Pane 已占用，不能以空 Split Picker 替代；通过 DEBUG 一次性 history reader 失败夹具，不注入真实网络或秘密。
- [x] 取得共同流程中的行为 RED。
- [x] 将现有 open 内部的成功/取消/读取与提交失败返回为明确结果，保留 preparation ticket、selection 和 arrangement 检查。最近 sheet 用局部失败状态消费 result；列表错误另消费只读 listing error，避免来源混用。空 Picker 继续消费自己的 split error，并由明确 failed outcome 更新。
- [x] 结果发布核对当前 sheet 操作身份；成功清错误/关 sheet，真实失败保留旧 Pane并展示重试，取消/过期安静退出，不保留上一操作的错误。
- [x] 取得完整 GREEN，复查 primary Recent、Search/Preview return、Split replacement 与 native iPad axis。

## 最终 Gate 与交付

- [ ] 最后一项通过后冻结最终 SHA、tree、base、包含的修复提交与 PR 关系。最终候选必须是完整 CI 实际测试的同一 tree，不用早期 V11 或图标专项替代。
- [ ] 如果最后一项的完整 CI 已覆盖冻结候选且源码/tree 未变化，可直接使用该证据；只有代码再变化、验证失败或缺少轴时补跑，不重复无意义构建。
- [ ] 将每项 RED/GREEN、job scope、实际 skipped/failed/restarted 状态、review 结果写入 `tasks/stage5-handoff-repairs.md`。创建 draft PR 时附到当前聊天；未获合并授权保持未合并。
- [ ] 交付代码/CI状态和待实机清单：中文 IME marked text、选区、连续切 active Pane、键盘/旋转、Lift/Return 中断、删除 Undo、长会话内存/帧时间。这些必须在安装包对应的候选源码上由实机验收证明。
- [ ] 用户完成整合 review 后另行决定合并/打包/实机步骤。四项修复 GREEN 不等于 Stage 5 实机验收完成。

## 计划自检

- 四条 review 均有实际入口测试、最小生产责任边界、失败/取消约束和独立 RED→GREEN。
- 第 1 项不把 `seed: .active` 当作未落库草稿复现；第 2 项不以重新打开 Pane 绕过缺陷；第 3 项不以旧 providerSetup 测试绕过正式路由；第 4 项不以空副 Pane 代替已占用场景。
- 任务 2 与 3 串行共享配置职责文件；其余维持现有边界。新增类型/方法是本计划的实现决策，不声称为现有 API。
- 2026-10-08 执行记录：四项代码/测试均已有实际完整 RED→GREEN，详见 `tasks/stage5-handoff-repairs.md`。最终候选另含一项已确认的测试清理修正，必须以该交付 commit 自身关联的完整 CI 与交付回复核对最终 Gate。下列发布后核对项在本文提交前不虚构完成；用户整合 review 与实机验收仍待后续进行。

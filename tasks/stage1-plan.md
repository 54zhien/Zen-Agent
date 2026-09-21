# Stage 1 — 审计与最小垂直切片计划

> 状态：**历史规划快照。Stage 1 已完成；最终实现与证据见 `tasks/stage1-closure.md`。**
> 下文保留开工前审计原貌，不代表当前仓库状态。
> 审计对象：本仓库真实状态（`App/`、`Tests/`、`project.yml`、CI）+ Blueprint 中
> Stage 1 / Provider 与模型 / 消息与数据 / 工程与发布 相关内容。

---

## 一、Stage 0 已经给 Stage 1 什么

先看清楚**不用重做**的部分，否则会在已有实现上叠第二套。

| Stage 1 条目 | 现状 |
|---|---|
| **1. Conversation / Message / Part 基础模型与 Repository** | **大体已有**。`ConversationRecord` / `MessageRecord` / `MessagePartRecord` + store API + `messagePart` 的 `pending/streaming/completed/failed/cancelled` 状态 |
| **2. AgentRun / AgentStep / ToolCall 持久化骨架** | **AgentRun ✓、ToolCall ✓、AgentStep ✗** |
| 3–8（Credential / Provider / Transport / DeepSeek / streaming 归一化 / ModelDescriptor / PromptComposer） | **完全没有**。已逐个核对：`Provider`/`Credential`/`Transport`/`ModelDescriptor` 在 `App/` 下的命中全是注释与枚举名，不是实现 |
| 9. FileAsset 最小边界 | 无。且**被未定项 8 阻塞**（见下） |

**超出 Stage 1 清单但 Stage 0 已经做了的**：删除生命周期（`visible/pendingDeletion/finalizedDeletion`）、
active Run 唯一性的数据库约束、tombstone。这些在 Blueprint 里属于更后的 Stage，
但它们由 Stage 0 的 spike 证明过，已成正式层的一部分——**不回退，也不扩大**。

---

## 二、代码侧发现（Stage 1 会立刻遇到）

### 1. `PersistenceStore` / `ZenDatabase` 不是 `Sendable`
`App/Persistence/PersistenceStore.swift:49`、`App/Persistence/ZenDatabase.swift:17`。
Stage 0 全程同步使用，没暴露。Stage 1 引入 async transport 后**编译器会立刻报错**。
两者**本来就能 Sendable**（`DatabaseQueue` 在 GRDB 7 里是 Sendable），只是没声明。
**必须在写第一行 async 代码前定，不是遇到再修。**

### 2. `requestConfigSeed` 是一个不透明 JSON 字符串
`AgentRunRecord.requestConfigSeed: String`。Blueprint 要求它冻结
ProviderInstance / Model / capability-validated options / credential binding revision
（`Agent Runtime.md:178`）。现在谁都能往里塞任何东西。Stage 1 要给它一个**有类型的形状**。

### 3. 只有一个 `PersistenceStore`，没有按业务聚合拆 Repository
Blueprint 明确建议「按业务聚合拆分，而不是按每张表机械一一对应」（`消息与数据.md:273`）。
Stage 0 用 `PersistenceStore` + 3 个 extension 文件。**是否需要拆，取决于 Stage 1 是否真的
出现第二个写入边界**——不为了形式而拆。

### 4. 没有 AgentStep / Attempt 实体
Stage 1 条目 2 点名要 `AgentStep`。而且拒绝 stale delta 需要 Step/Attempt identity。

### 5. 没有 provider 失败的错误词汇
现在只有 `PersistenceError`（5 个 case）。Blueprint 要求 Transport 归一化出
`retryable / rateLimited / authRequired / retryAfter` **以及「请求尚未被接受」**
（`Provider 与模型.md:68`）。

---

## 三、Blueprint 内部不一致 / 待裁决

抽查过原文，以下均为**属实**：

| # | 冲突 | 位置 | 我的读法（待确认） |
|---|---|---|---|
| 1 | **Run snapshot 归属**：数据侧把「Streaming snapshot + Run execution snapshot/revision + Step/Attempt identity」写成一步；Stage 表把「Run snapshot 边界」放在 **Stage 2** | `消息与数据.md:469` vs `开发规划.md:278` | **拆开**：AgentStep/Attempt 的**记录**属 Stage 1（条目 2 点名要）；Run execution snapshot 的**内容与使用**属 Stage 2。Stage 1 只建骨架，不填语义 |
| 2 | **未定项 8 明写「应在 Stage 1 前定」**（FileAsset 物理位置 / iCloud 备份），而 FileAsset 是 Stage 1 条目 9 | `开发规划.md:555` | 条目 9 本身是**条件项**（「如果 Stage 3 要实现图片/文件入口」）。倾向：**把条目 9 整体推到 Stage 3**，届时连同未定项 8 一起定——但这是产品决定 |
| 3 | **Stage 1 Gate 需要真实 DeepSeek key**，但无开发期 Secret 注入方案 | `开发规划.md:249` + `工程与发布.md:166` | Gate 的 DeepSeek 那半不能在普通 CI 上跑（`工程与发布.md:166` 明令「不要让所有 CI 都依赖真实第三方 API」）。需要定注入方式 |
| 4 | **Retry 语义（未定项 5）未定**，但 Stage 1 的 AgentRun 骨架要表达「是否为某个更早 Run 的重试」 | `开发规划.md:552` + `消息与数据.md:119` | 字段可以先建、**语义不实现**。未定项原文已说「未确认前隐藏 Retry」 |
| 5 | **Data Protection 分层**在 `安全与权限.md` 里排在 §16 第 13 步（较后），但 Stage 1 建库时就该定 | `安全与权限.md:311` vs `消息与数据.md:427-432` | 建库时就要定，否则后补要迁移 |
| 6 | Blueprint 仍写「不提前拍板 SwiftData 还是 GRDB」，而 Stage 0 已选定 | `消息与数据.md:457`、`工程与发布.md:290` | 按 `AGENTS.md` 的单向回写流程，**Blueprint 应被更新**（这是 Blueprint 的活，不是本仓库的） |

---

## 四、Stage 1 最小垂直切片计划

按你给的 Increment 划分，但**按审计结果调整**——第 1 项比预想的小得多。

### Increment 1：补齐 Stage 0 遗留的数据层缺口
**不重写已验证的 Persistence。**
- `Sendable` 边界定下来（在 async 出现之前）
- `requestConfigSeed` 给出有类型的形状
- `AgentStep` / `Attempt` 骨架（只为 stale-delta 拒绝提供 identity，不含语义）
- 补对应 regression test

**产出**：数据层就绪，可以承接 Provider 而不需要回头改。

### Increment 2：CredentialStore / Keychain 边界
- 只保存 credential reference；Secret 绝不进入 GRDB
- 用 fake credential 验证生命周期（含 binding revision 语义）
- Keychain accessibility 与后台需求一起定（`安全与权限.md:104,111`）

### Increment 3：Provider / ProviderInstance / ModelDescriptor 协议
- 先 fake Provider；**不提前实现 AgentRuntime**

### Increment 4：DeepSeek Transport（非流式）
- API key 从 CredentialStore 解析
- provider-specific raw payload 不泄漏到核心层

### Increment 5：SSE Streaming transport
- partial event assembly / UTF-8 / malformed / inactivity timeout / HTTP failure / cancellation
- **禁止危险的自动重试**

### Increment 6：Streaming event normalization
- DeepSeek raw event → provider-neutral event
- stale attempt/delta 必须可拒绝

### Increment 7：ModelDescriptor / capability
- reasoning effort 等 option 必须 capability validated
- 不在 UI/Runtime 按 model name 散落判断

### Increment 8：最小 PromptComposer
- 仅 Runtime/Safety baseline + 最小 Zen Core + Provider Adapter + Conversation History + Current User Message
- **不接 Soul / Memory / Skill / MCP**

---

## 五、Stage 1 Gate（Blueprint 原文）

> 通过 Provider/Repository 的最小 harness（**不要求完整 AgentRuntime**）能用
> **fake + DeepSeek** 完成稳定文本 Streaming，并**重启后恢复已保存 Conversation**。

---

## 六、不做的事

`AgentRuntime` 主循环（Stage 2）、`ToolRuntime`（Stage 2 最小 / Stage 6 完整）、
真实 Tool executor（Stage 6）、Conversation UI（Stage 3）、
Soul（Stage 4）、Memory（Stage 7）、Skill（Stage 8）、MCP（Stage 9）、Subagent（Stage 10）。

---
status: accepted
date: 2026-09-19
---

# 持久化引擎选型推迟到 Stage 0 的 spike

我们不在 v0.9 确定用 SwiftData 还是 GRDB，而是在 Stage 0 加一个一次性 spike，
用同一组测试分别验证候选方案后再记录结论。

## 为什么需要这个决定

Zen Agent 对数据库的控制要求高于普通 App：Send commit 需要原子事务、
Run 需要可恢复的 execution snapshot、ToolCall 需要 dispatch 前的 checkpoint、
外部副作用需要 indeterminate 状态机、迁移需要可中断可重试、删除需要两阶段、
未来还要 FTS。这些需求听起来会让人直接得出「SwiftData 撑不住」的结论。

但那个结论是**静态推断，不是验证结果**。截至 2026 年，SwiftData 已支持
`VersionedSchema`、`MigrationStage.custom`、`#Unique` 复合唯一（iOS 18+）、
`#Index` 复合索引（iOS 18+）与事务。据未经核实的印象就排除它，
等于把一个可能可用的方案提前砍掉，并且把这个未经证实的判断固化进设计基线——
这正是本轮收口要清理的病灶。

## Considered Options

- **直接选 GRDB**：控制力最强，但可能是为不存在的问题付出长期成本。
- **直接选 SwiftData**：Apple 原生、与 Swift 生态一致，但迁移与并发行为需要实测确认。
- **跑 spike 再定**（已选）：成本是一次性的小规模验证，收益是决策有据可依。

## 验证判据

spike 用**同一组测试驱动两个候选**（一个共享 harness 协议，两套实现），而不是写两份测试套件——
否则比较的是两份测试而不是两个引擎。七个场景全部覆盖，细节与「失败意味着什么」写在
`Spikes/Persistence/README.md`：

| # | 场景 | 核心问题 |
|---|---|---|
| A | Atomic send commit | User Message + Parent Run + frozen seed 能否在一个事务内完成，崩溃后不留半状态 |
| B | Double-send race | 并发下「同一 Conversation 至多一个 **非终态** Parent Run」能否被原子保证 |
| C | Tool dispatch crash | 能否区分「已准备未 dispatch」与「可能已 dispatch」 |
| D | Migration interruption | 迁移中途中断后能否重跑且不重复破坏 |
| E | Delete / Undo | `pendingDeletion` 阶段正文完整保留、Undo 能恢复完整对话 |
| F | Tombstone | Conversation 删除后，indeterminate 操作的最小追踪记录不被 cascade 抹掉 |
| G | Streaming write pressure | 大量 delta 下写入次数与阻塞情况 |

**B 是决定性的一条。** 它要求的是**条件唯一性**（「至多一个**非终态** run」），
而两个候选都没有一等 API 表达它——标准解法是可空的 active-slot 列（活跃时等于 conversationID、
终态时置 NULL）加唯一索引，因为 SQL 认为 NULL 互不相等，从而允许多条终态行共存。

## 已由 CI 实测的证据（2026-09-19）

不是推理，是跑出来的结果。CI runs 35421484359 / 35421773153 / 35422701520。

### 场景 B 的对照结果

两个引擎跑**同一个 8 并发写者竞争**、用**同一个 `ClaimOutcome` 计分**，结果可直接比较：

| | SwiftData | GRDB |
|---|---|---|
| 机制 | 事务内 fetch-then-insert | 声明的 partial unique index |
| 赢家 | **3** | **1** |
| 干净拒绝 | 5 | 7 |
| 报错 | 0 | 0 |
| 最终持有 slot 的行数 | **3** | **1** |
| 结论 | **不变量被破坏** | **不变量成立** |

SwiftData 的 `won=3, errored=0`：三个独立事务各自读到 0、各自插入、各自提交，
**没有任何一方报错**。`ModelContext.transaction` 没有把 check 与 write 串起来。

两者机制的差别是刻意的：GRDB 那条**不依赖引擎串行化「读」与「之后的写」**，
而 SwiftData 那条必须依赖。已核实 Apple 文档：**`ModelContext` 不暴露任何隔离级别控制**，
只有 `transaction(block:)`，没有等价于 `BEGIN IMMEDIATE` 的入口——所以这条依赖在 API 层面无法满足。

顺带一条同样重要的观察：**SwiftData 的两轮实验都恰好是 3 个赢家**。
它不是"稳定地失败"，而是**有时会看起来通过**。若 CI 上偶然跑出 1 个赢家，
会读起来像绿——到并发压力不同的生产环境才炸。

### 声明式唯一约束的实测语义

| 结论 | 证据 |
|---|---|
| **SwiftData 的 `#Unique` 不拒绝，而是静默 upsert** | `rows after save: [active-2/slot=c1]`——`active-1` 消失且无任何错误 |
| **改成非空 slot 也一样 upsert** | `rows for slot c1: [active-2]` |
| GRDB 用 partial unique index 正确拒绝第二个占位者，多条终态行共存 | 接线测试通过 |

对互斥状态来说，upsert **比完全没有约束更糟**——约束毁掉了它本该保护的那一行。
但这是**一个机制出局，不是引擎出局**：upsert 对面向合并的存储是合理设计，
拿它当互斥约束用是类别错配，不是 bug。

### 串行 owner 这条退路：产品已裁定（2026-09-19）

蓝图 `消息与数据.md` 原文允许「事务、**串行 owner**、约束或等价机制」，
所以 SwiftData 仍有一条路：用一个串行化所有 Run 创建的内存 actor。

**产品决定记录如下**，它界定 B 的结论意味着什么：

- **spike 阶段允许它作为 SwiftData 的备选实现继续参与 C–G 验证。**
- **正式 Zen V1 不把「单进程 actor」当作理想最终保证。**
  理由：这是一条 Runtime 核心不变量，不是普通优化。一旦破坏，
  同一个 User Turn 会长出两条 Run，进而双 Streaming、双 Tool Call、双 Approval、
  恢复状态竞争、Message projection 污染。
  期望的保护是 **application serialization + database constraint 双层**，
  而不是指望所有调用路径永远记得经过某个 actor。
- **多 Scene 不构成额外进程边界**；真正要记录的限制是 **App Extension / 第二进程**，
  以及**绕过该 owner 的其他写路径**。

    Fallback:  App-process-wide serialization actor
    Coverage:  ✅ 同进程
               ✅ 多 Scene（不是进程边界）
               ❌ App Extension / 第二进程
               ❌ 绕过该 owner 的其他写路径

**不要为了救 SwiftData 而设计一个 `ActiveRunLease` 唯一约束就宣布问题解决。**
若要做这个额外实验，必须验证它提供的是**真正的 claim 语义**
（winner=1、loser 明确 rejected），而不是仅仅让数据库里最后剩一行——
后者正是已实测到的 upsert 行为，与需求相反。

### 场景权重（产品给定，决定证据如何汇总）

七个场景**重要性不均等**，不能用「1/7」理解进度：

| 权重 | 场景 |
|---|---|
| **最高** | B 唯一性 · C dispatch crash / indeterminate · D migration / recovery |
| 中高 | A atomic Send · G Streaming 写入压力 |
| 中等 | E Delete / Undo · F Tombstone |

判读原则：**若 GRDB 在 B + C + D 上明显更自然、更强，即使 SwiftData 在 E/F 更省代码，
仍应偏向 GRDB。**

SwiftData 唯一还剩讨论价值的组合：C–G 上它**明显**更可靠或更简单，
只有 B 需要一个全局 actor，且 Zen V1 明确不做 App Extension、所有 Run 创建只有一个 Repository owner。

### 尚未验证的部分

场景 C–G **对两个引擎都还是空白**。目前只有 B 一条决定性证据指向 GRDB——
按上表它是最高权重之一，但**单条证据不构成选型**。

## 已核实的环境事实（2026-09-19）

- **GRDB 最新 v7.11.1**（2026-06），要求 Swift 6.1+ / Xcode 16.3+，iOS 13+ / macOS 10.15+。
- **GRDB 与严格并发有已知摩擦**：Swift Package Index 的构建显示其仍有 Swift 6 data-race 诊断；
  GRDB 7 官方建议在开启严格并发检查前把 `Record` 子类重构为 struct。
  本项目已选定 Swift 6 language mode，因此**这份摩擦是决策的一部分，不是脚注**。
- **`macos-26` runner 已 GA**（2026-02-26），arm64，自带 Xcode 26.x（当前默认 26.6）。
- **spike 用 macOS logic-test bundle 跑，不用 Simulator**：被测语义与平台无关，
  而 macOS logic test 在 CI 里快一个数量级，且不需要 host app。

## Consequences

- **执行环境限制**：spike 需要编译 Swift，而本机是 Windows 且无工具链，
  因此只能在 GitHub Actions 的 macOS runner 上运行。spike 放在一次性分支或临时 target，
  结论定下后连同 `PersistenceSpikeTests` 一起删除，只留本 ADR 的结论更新。
- **两个已知陷阱需写入 spike 说明**：SwiftData 的 migration 测试必须跑真实 store——
  Simulator 重建会删库，迁移代码可能根本不执行，导致测试假绿；
  另外 SwiftData 官方建议 CloudKit 场景避免 unique 约束，自定义迁移在 CloudKit 下会崩。
- **落选引擎的代价也要记录**：若将来重新考虑，理由应当已经写下来。

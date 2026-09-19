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

不是推理，是跑出来的结果（run 35421484359 / 35421773153）：

| 结论 | 证据 |
|---|---|
| GRDB 解析为 SPM 依赖并可用 | 接线测试通过 |
| **GRDB 用 partial unique index 正确拒绝第二个占位者**，多条终态行共存 | 接线测试通过 |
| SwiftData 在本 target 可用，多 NULL slot 共存 | 接线测试通过 |
| **SwiftData 的 `#Unique` 不拒绝，而是静默 upsert** | `rows after save: [active-2/slot=c1]`——`active-1` 消失且无任何错误 |
| **改成非空 slot 也一样 upsert** | `rows for slot c1: [active-2]` |

第二组结果对 B 的含义：**SwiftData 的声明式唯一约束不只是"没生效"，它会主动破坏不变量。**
第二个写者本应干净地失败，实际却是第一个 active run 被无声覆盖。
对互斥状态来说，这比完全没有约束更糟——约束毁掉了它本该保护的那一行。

**但这判定的是一个机制出局，不是引擎出局。** upsert 对面向合并的存储是合理设计，
把它当互斥约束用是类别错配，不是 bug。SwiftData 是否还有别的机制能守住 B，
由 `Scenario B probe`（8 个并发写者、显式声明不带唯一约束的模型、事务内 fetch-then-insert）回答。
只有当那条路也失败时，才能说 SwiftData 无法表达 B。

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

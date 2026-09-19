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

### 场景 G 的对照结果（中高权重）

设计遵循一条原则：**把稳定可判定的属性写成断言，把时序数字打印出来**。
在共享 CI runner 上把耗时写成阈值必然 flaky，而按产品的判读标准
「两边都够快，性能差一点也不构成淘汰理由」——所以它该被测量，不该被裁判。

**断言 6/6 全过，两边对称**（各 3 条）：

| 断言 | GRDB | SwiftData |
|---|---|---|
| 600 delta 经 batch=50 后持久化总数正确 | ✅ | ✅ |
| **写入次数确实塌缩**（不是每 delta 一次写） | ✅ | ✅ |
| **终端 flush 是重开后存活的那个** | ✅ | ✅ |
| 写入提交期间读能完成、不被阻塞 | ✅ | ✅ |

**控制性属性上 G 是平局**：两边都是 **12 次写入**（600/50），终态 flush 都是重开后读到的值。

**测量数字（打印，非断言）**：

| | GRDB | SwiftData |
|---|---|---|
| 写入次数 | 12 | 12 |
| wall | **26.6 ms** | 69.1 ms |
| 写入 P50 / P95 | **1.68 / 3.56 ms** | 4.21 / 7.72 ms |
| **store 体积** | **20 KB** | **139 KB** |
| 读 P95 | 0.15 ms | 0.20 ms |

**这些数字按产品给定的标准不构成淘汰理由**——12 次写入、单次 2–8 ms，两边都远超够用。
唯一值得记的是**体积差 6.8 倍**：长对话中 Run/ToolCall/Part 持续累积，
CoreData 的元数据开销（`Z_PK` 等）会同比放大。这是数据点，不是否决项。

### 场景 A 的对照结果（中高权重）

A 拆成两种**不同**的失败：A1 事务体内主动失败必须回滚；A2 进程带着未提交的工作死掉必须什么都不留。
每个测试都带**负对照**——先证明这个探针**能看见**半状态（分别提交两半然后停住），
否则"没有出现半状态"什么都证明不了。

| | A1 回滚 | A2 无残留 | 负对照 |
|---|---|---|---|
| **GRDB** | ✅ | ✅（见下） | ✅ |
| **SwiftData** | ✅ | ✅ | ✅ |

**A 是平局。** 两个引擎的单事务原子性都成立。

按五维记账：

| 维度 | GRDB | SwiftData |
|---|---|---|
| Correctness | ✅ | ✅ |
| Enforceability | 数据库事务 | 数据库事务 |
| Failure injection | A1 可注入；**A2 的"带事务被杀"不可注入** | A1/A2 均可注入 |
| Diagnostics | 抛出的错误原样返回 | 抛出的错误原样返回 |
| Recovery | 重开后状态明确 | 重开后状态明确 |

**一条反直觉的可注入性发现**：GRDB **拒绝**留下悬开的事务——

    GRDB/SerializedDatabase.swift:131: Fatal error:
    A transaction has been left opened at the end of a database access

这是 `fatalError` 而非可恢复错误，直接把整个测试 bundle 打崩、CI 重跑了一遍。
**GRDB 在这里是更安全的**（那个状态不可能被意外制造出来），
但代价是 **"带事务被杀"这个窗口通过 GRDB 的 API 无法注入**，
所以它的 A2 只能建立正向那半（已提交的 send 整体持久化）+ 负对照。

**注意这个不对称的走向**：SwiftData 没有这个守卫，所以它的 A2 能直接模拟并通过。
**在这里能被测试的，恰是守卫更少的那个引擎。** 这是关于可测试性的事实，
不是关于谁更安全的结论——README 里两者分列。

### 场景 C 与 D 的对照结果

| | C 崩溃窗口 | D1 正常迁移 | D2 重复打开 | D3 中断恢复 |
|---|---|---|---|---|
| **GRDB** | ✅ | ✅ | ✅ | ✅ 回滚并续跑 |
| **SwiftData** | ✅ | ✅ | ✅ | ✅ store 仍可用、数据完好 |

**C 是平局。** 两个引擎都能把「已准备但未 dispatch」与「可能已 dispatch」持久化地区分开。
（此前担心的「SwiftData 不允许重新打开自己的 store」被证伪。）

**D 上 SwiftData 全部通过，但带两条实测的负面发现**，都属**诊断性 / 人体工学**，
不属**正确性**——不能读成「迁移不安全」：

1. **新增的非可选属性会让迁移直接失败**：
   `Validation error missing attribute values on mandatory destination attribute (entity=Note, attribute=pinned)`。
   已有行没有值，SwiftData 不会替你编；**构造器默认值不管用**（那是构造器默认，不是 schema 默认）。
   这就是「一次升级之后 store 打不开」的形状。可行形状是**可选属性 + `didMigrate` 回填**。
2. **迁移失败会丢弃原因**：注入的错误确实传进 CoreData 并中止了迁移
   （CoreData 日志：`returned error … MigrationInterrupted (1)`），
   但 SwiftData 把它包成 `SwiftDataError(.loadIssueModelContainer)` 且 `_explanation: nil`。
   调用方**无法区分**「我的迁移代码抛错」「schema 不对」「store 损坏」。
   对一个「迁移失败 = 用户打不开应用」的产品，这是实打实的损失。

另记录一条**可控性**事实：SwiftData 的迁移在 `ModelContainer` 初始化时隐式发生，
公开 API 没有步进 / 暂停迁移的入口；也无法查询 store 当前处于哪个 schema 版本。
因此它的 D3 只能注入**受控失败**（迁移阶段内抛错），不是「写到一半被 kill」。

按三维度记账（Correctness / Enforceability / Testability），B+C+D 的现状：

| | Correctness | Enforceability | Testability |
|---|---|---|---|
| **GRDB** | B ✅ · C ✅ · D ✅ | **B 由数据库约束保证** | 三个场景均可复现 |
| **SwiftData** | B ❌ · C ✅ · D ✅ | B 只能靠应用纪律 | D3 只能注入受控失败；失败原因不可读 |

**判读**：GRDB 在 **B 上决定性领先**——不是「某个 API 更方便」，而是
**不变量由数据库保证** vs **靠应用纪律**，这是两个可靠性层级；
在 **D 上小幅领先**（同样通过，但无那两条负面发现）；**C 平局**。

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

**B、C、D 三个最高权重场景已在两个引擎上跑完**（见上）。
剩余 **A（atomic send，中高）、G（流式写入压力，中高）、E（删除+Undo，中）、F（tombstone，中）**
对两个引擎仍是空白。

按产品给的判读原则，B+C+D 这一组已经足以形成倾向：**GRDB 在 B 上决定性领先、D 上小幅领先、C 平局**。
但在 A/G 未测之前**不作最终选型**——中高权重的两项还没数据，
而且 A（Send 原子提交）与 B 同属「一个事务里的复合写入」问题族，它的结果可能补充或削弱 B 的结论。

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

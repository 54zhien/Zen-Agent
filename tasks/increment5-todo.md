# Stage 1 · 前置修复 + Increment 5（Streaming）执行清单

> 状态：**历史执行快照。Increment 5 已完成并纳入已 CLOSED 的 Stage 1；Stage 1 最终实现与证据见 `tasks/stage1-closure.md`。**
> 下文保留 Increment 5 当时的执行清单、RED/GREEN、review debt、CI 诊断与后续修复记录，不代表当前待办或当前阶段状态。
> `tasks/todo.md` 是 Stage 0 的历史记录（含 Review 段），不被覆盖。

**纪律**：小步提交 → 每步 CI 验证 → 增量结束停下等确认。CI 失败即停下重新规划，不硬推。
**推送**用 `if git push` 判断，不用管道（handoff `:61`）。

**已知约束**：CI 有 `cancel-in-progress: true`，同一 ref 上推新提交会取消正在跑的验证 ——
所以必须等上一次跑完再推。

---

## 前置 P：冻结完整 Credential Binding Identity

- [x] P1–P7 全部（`CredentialBindingSnapshot` / 校验 reference+generation / 删泛型 upsert /
      新 `providerInstanceAlreadyExists` / 新 suite `FrozenCredentialIdentityTests`）
- [x] **CI 绿** `35434791623` → success，**110 测试 / 15 suite**

**P6 存储兼容性**：seed 形状变更使已存 seed 无法解码。pre-release、无线上数据 → 干净切断，
**显式决定，非疏忽**。

---

## Increment 5

| 步 | 内容 | CI |
|---|---|---|
| 5B | SSE parser | `35435036167` **failure** — `finish()` 是 mutating，不能对临时值调用 |
| 5A | Streaming transport + 5B 修复 | `35435234355` **failure** — 4 个失败，全在测试支撑层 |
| 5C | DeepSeek streaming wire format + 桩并发修复 | `35435579220` **failure** — 剩 2 个，仍是桩的问题 |
| 5D+5F | Timeout 分层 + Base URL 单真值 + 桩串行修复 | `fb88c66` → `35435945399` **failure**（4 个失败，全在测试支撑层）。**该步没有单独成功过** |
| 5E+5G | 真取消 + 分类收尾 | `5e0aeb7` → `35436363149` **cancelled**（被同 ref 后一次推送取代）。**该步没有单独成功过** |

**5D+5F 与 5E+5G 各自都没有一次单独的成功 run。** 两步的代码首次随**同一次绿运行**
通过：`35441053882`（`11bff63`）→ success —— 那次同时包含 5A–5G 与 `/code-review` 的修复，
且当时两条集成测试**已处于 disabled**。该次是否为「单次干净运行」**当时未核实**；
test-host restart 问题是在其后的 run 里才被发现的。

**三次失败全部在测试支撑层，没有一次是产品代码。** 共同点：都是「断言正确行为」而非
「描述现状」的测试抓出来的 —— 桩按并发投递、桩把整条连接塞进一个 runloop turn，
都是产品代码没错、测试基础设施在说谎。

- [x] 5A `HTTPTransport.stream` → `AsyncThrowingStream<Data, Error>`
- [x] 5A `HTTPTransportError` + `.httpStatus` / `.streamInterrupted(deliveredData:)`
- [x] 5B `SSEParser` 纯逻辑 + 有界缓冲（闭合 Blueprint `:61` 自己的空洞）
- [x] 5C `DeepSeekStreamChunk` + `DeepSeekProvider.stream` 三层合流
- [x] 5D `StreamTimeoutPolicy` + `StreamDeadline` + `StreamProgress`
- [x] 5F `resolveBaseURL(for:)`，两条路径共用；删除 provider 自带 baseURL
- [x] 新增 CI hygiene：DeepSeek 类型只能在 adapter 内**声明**
- [x] 5E `StreamingCancellationTests`（`stopLoading` 真被调用 + 取消后不再交付）
- [x] 5G 分类缺口补齐（malformed SSE / 首个事件前断流 / parser 错误映射）
- [x] `/code-review` 跑 diff → **4 个真实 bug 已修**（见下）
- [x] **CI 全绿** `35441053882` → success —— 但**该次并非干净运行**（含 test-host restart），
  当时的 `181 / 23` 是「逐名合并」的重建值，**不是**任何一次真实运行的规模。见文末。
- [x] **两条 disabled 集成测试已迁移到 localhost harness 并重新启用**（见下）。
  其中 **Test B 不能沿用 `.chunkThenDisconnect`**：`LocalHTTPServerCharacterisationTests`
  实测记录该脚本到达 `bytes(for:)` 是 ***clean end***，**不是**抛出错误；而 Test B 断言的是
  **抛出的** `.streamInterrupted`。所以它需要一条**新的 abortive close**（`.chunkThenAbort`，
  `SO_LINGER` 零间隔 → RST）。这个区分是本增量的实质，见下节。

### 两条集成测试的迁移结果

**已合并到 `main`：`9056e8c..625bb43`（fast-forward，三个 commit）**

| commit | 内容 |
|---|---|
| `f567cbe` | 密封 accepted 描述符发布竞态（检查 + 发布合入同一把 lock，附确定性回归）；新增 abortive close 能力（`chunkThenAbort`，`SO_LINGER` 零间隔），与**未改动**的 graceful 路径并存 |
| `64c6e50` | 两条测试迁移到真实 socket 并重新启用 |
| `625bb43` | 把「立即读计数器」换成**有界地等待事实成立** |

**改动范围**：6 个文件，全部在 `Tests/ZenAgentTests/` 下；375 insertions / 177 deletions。
**没有任何 `App/` 文件被改动。**

| 测试 | 需要的 server 行为 | 实际获得 |
|---|---|---|
| Test A `StreamingCancellationTests.cancellationReachesTheNetworkWithoutAFailure` | 发合法 SSE → consumer 收到 → stall → cancel | `.chunkThenStall(validSSE)`；`StubURLProtocol.stopCount` 换成 `server.observedPeerClose`；保留 30s policy、consumer 侧 readiness、`nil \|\| .cancelled` 结果断言 |
| Test B `URLSessionHTTPTransportTests.failureAfterObservedDataIsInterrupted` | 发 partial → consumer 收到 → **触发抛出型断开** | **`.chunkThenAbort("data: partial ans")`**，**不是** `.chunkThenDisconnect`；只在完整 body 进入 `received` 后调一次 `requestClose()` |

**Test B 的门槛是「先特征化、再恢复」**：`.chunkThenAbort` 先被单独测过
（`an abortive close after delivery throws, unlike the graceful one`），该测试要求结果**以
`threw ` 开头**。它通过，证明 `SO_LINGER` 零间隔在本平台确实产生 RST ——
即 Test B 所需的**抛出型中途失败是可制造的**。若不通过，Test B 应保持 disabled 而
**不得放宽断言**；这个顺序是刻意的。

两条测试的断言**逐字未改**。**未改 production `URLSession.bytes(for:)`**，也不切 delegate。

**分支上的 run 记录**：`35490301749`（`625bb43`，success）· `35489164861`（`64c6e50`，success）·
`35488849050`（`f567cbe`，success，重跑）· `35488461525`（`f567cbe`，**failure**）。

### `/code-review` 查出并已修的 4 个 bug（出厂配置下均可达）

1. **liveness 死线从未生效**：`init(session:timeouts:)` 存了 policy 却没告诉 session，
   URLSession 自己的 60s idle timer 抢先触发且 `URLError.timedOut` 无人映射 →
   静默被报成断线。**配置的 180s 窗口与整个 `inactivityTimeout` 是死代码。**
2. **「进展」=「来了个 chunk」而非「模型产出了东西」**：DeepSeek 首 chunk 只有 role + 空
   content；代理连发 `delta: {}` 会**永远重置**计时器 → stall 检测永不触发。
3. **retry 判定用字节而非输出**：keep-alive 是字节 → 心跳一分钟后断线被当成「已交付」→
   禁止重放；两种情况本该相反。`ProviderError` 字段改名 `deliveredOutput`。
4. **错误体 drain 吞掉取消**：用户按 Stop 时流式 401 显示「凭据被拒绝」。

另修 2 个测试完整性问题：取消测试的「不再交付」断言**不可能失败**（在消费者侧计数，
改到生产侧）；桩的两个终态分支缺 `isStopped` 检查。

### `/code-review` 查出、**本增量未修**的（留给后续）

| # | 问题 | 影响 |
|---|---|---|
| A | `onTermination = { task.cancel() }` 与 task 捕获 continuation 构成**引用环**；`.done` 路径不取消上游 | 每个正常结束的流泄漏一个 task + 连接；provider 发完 `[DONE]` 后保持连接时，keep-alive 无限缓冲 |
| B | `hasAdvanced` 分两次加锁读取（`elapsedDeadline` 选窗口、调用方选 phase） | 极端竞态下 phase 与窗口不匹配，`retryDisposition` 翻转 |
| C | `FakeHTTPTransport.stream` 不实现任何生命周期（不产 `.httpStatus`、不产 `.cancelled`、不检查取消）；`deliveredData` 由测试手写而非推导 | provider 测试可能通过真实 transport 产生不了的事实 |
| D | `requestConfigSeed` 改形状**无迁移、无逐行容错** | 任何旧行让该 conversation 的所有 run 读不出来；CI 看不见（`MigrationTests` 只用新形状种数据） |
| E | `reconfigureProviderInstance`/`attachCredential` **读在一个事务、写在另一个** | 中间被删 → 裸 GRDB `RecordError` 逃到调用方；并发编辑静默丢失一次更新 |
| F | 解析出的 endpoint **不在 frozen seed 里** | 实例 `baseURL` 为 nil 时冻结的 run，resume 后可能把凭据发到换过的默认 host，`FrozenConfiguration` 全绿 |
| G | `.streamInactivityTimeout` 在**适配器侧**没有输出判定前，transport 的字节事实与模型的输出事实仍可能在极端路径混同 | 已修，但 B 的竞态是同一处 |

A 和 D 是其中影响最大的两条。

### 上表的处置（`inc5-review-debt` 分支，全部已对当前源码核实）

表是 review 当刻写的，之后没随修复更新，所以开工前逐条对过源码。结论：

| # | 状态 | 依据 |
|---|---|---|
| A | **不成立** | `DeepSeekProvider.swift:194` 的 `onTermination` 绑 `HTTPStream.cancel`（背后是 `URLSessionDataTask`），没有回到 continuation 的路径。`486cdc9` 已移除该环，`cb723b7` 清掉残留绑定 |
| B | **已修** | `4f68e4f`：窗口与 phase 来自同一次加锁快照 |
| C | **已基本修掉** | `FakeHTTPTransport.stream` 现在记录取消、head/tail failure 走 `HTTPTransportError`；`deliveredData` 仍为手写，未重开 |
| D | **已修** | `fdf1f87` + `3c88374` + `e201258`：逐行容错、typed error、旧形状 seed 的测试补上 |
| E | **已修** | 见下节 |
| F | **已修** | `db29f66`：seed 冻结完整 request endpoint 并在校验时比对 |

---

## E：单事务 CAS + 独立 edit revision（`inc5-review-debt`，2026-09-20）

**问题**：`reconfigureProviderInstance` / `attachCredential` **读在一个事务、写在另一个**，
且把读到的**整个对象**写回。后果两条：中间被删 → 裸 GRDB `RecordError` 逃到调用方；
并发编辑静默丢失一次更新（后写者用早先读到的整行覆盖）。

`PersistenceStore+ProviderInstances.swift` 的注释自称「it has to be impossible to change
an instance without changing what a frozen run compares against」—— 两次并发编辑都读到
revision N、都写 N+1，这句不成立。这不是遗漏，是**注释承诺了实现没有提供的东西**。

**做法**：读、判定、写收敛进同一个 `database.write`；更新带
`WHERE id = ? AND editRevision = ?` 条件，陈旧写入改 0 行而不是覆盖；
只更新该 mutation 允许改的列。

**两个计数器，不是一个**：`configRevision` 回答「冻结的 run 是否仍然匹配」，
所以 `attachCredential` 不能 bump 它（既有决定，未动）。检测丢失更新需要一个
**每次编辑都动**的计数器，包括凭据那一次 —— 一个列没法同时满足两件事，
所以新加 `ProviderInstanceEditRevision`（`INTEGER`，V5 migration，存量行从 0 起）。

**`ConfigRevision.next` 改为 fail-loud**：`Int(rawValue) ?? 0` 会把不可解析的值变成
`"1"`，也就是 `initial` —— 一个 run 可能已经冻结过的 revision，实例于是**在 run 的
checksum 没动的情况下被改掉**。改成抛出。（在 SQL 里原子递增**不能**修这个：
`CAST('config-r1' AS INTEGER)` 是 0，仍然得到 `"1"`。）

**红→绿**：
- `63f0867`（红）CI `35500976001` → failure。两条真红：
  - `a rename built on a stale snapshot does not revert another editor's endpoint`
    → `api.deepseek.com == proxy.example.com` 失败（A 的 endpoint 被 B 的陈旧写回滚）
  - `a revision that cannot be counted is not silently renumbered`
    → `"1" != "1"` 失败（`config-r1` 被静默重编号为 `1`）
- `7bce7f5`（绿）CI `35501448459` → success

**第 3 条探针没有红**，且原因是结论性的：旧 API **根本不接受调用方的快照**，
`attachCredential` 在内部重新读一次，所以「陈旧快照」在旧代码里无法表达。
这正是 E 的修法必须是 **API 变更**的原因 —— 必填的 `expectedEditRevision`
才让「基于陈旧快照的写入」成为一个可陈述的事实。

**`/code-review` 之后又修的两条**（都是本轮自己引入的）：
1. `createProviderInstance` 原样持久化调用方给的 `editRevision` —— 与 V5 注释的
   「存量行从 0 起」矛盾，并让「删除 → 用旧快照重建」绕过 guard。改为由 store 派生。
2. 两个 `next()` 的 `rawValue + 1` 在范围顶部**直接 trap**，而不是设计承诺的 typed
   refusal —— 而触发它的正是测试自己点名的威胁模型（手改 / 坏导入）。改为
   `addingReportingOverflow` + 抛出。

**5D 的证明性测试**（三条各证一件事，只有一个 timer 时必有一条红）：

| 输入 | 期望 |
|---|---|
| 只发 keep-alive，liveness 400ms | `.streamProgressTimeout(.awaitingFirstEvent)` |
| 状态行后彻底静默，firstEvent 10s | `.streamInactivityTimeout` |
| 先出真 chunk 再只发心跳 | `.streamProgressTimeout(.betweenEvents)` |

---

## 未核实 / 待报告

- `timeoutIntervalForRequest` 的 inactivity 语义：**未能**从 Apple 实时文档核实
  （页面 JS 渲染）。Blueprint `Agent Runtime.md:277` 明确断言 → 报告里标注「Blueprint 断言，未独立核实」。
- `FrozenCredentialIdentityTests` 在修复前会失败：**由前提推得**（测试断言了 B 的 generation
  确实是 1、revision 确实没动，旧代码在此时必然放行），**未实测**。
- `DeepSeekProvider.stream` 返回 DTO 类型 → 与「DTO 不出 adapter」有张力，属**临时**边界，
  Increment 6 换成 provider-neutral 类型。

---

## Review（增量结束）

Increment 5 的产出不是「流式功能」，而是**一条能被证伪的流式基线**：transport 的
cancellation 是一条显式的 `HTTPStream.cancel()` 一跳链；timeout 分成连接活性与模型进展两个
问题、各有自己的计时器；每一次「不再消费响应」的退出路径都结束真实网络传输。

代价与教训都记在上面：**产品代码的主要缺陷不是测试发现的，是 `/code-review` 发现的** ——
其中 3 个让增量的招牌功能完全不起作用，而测试全绿，因为测试自设了应用里从不使用的窗口值。
另有 5 条 review 发现、本增量未修，见上表（A 与 D 影响最大）。


---

## inc5-ci-restart 任务结论（2026-09-20）

### 根因

test-only 的 `LocalHTTPServer` 在 client cancellation 之后继续对已断开的 peer 调用 `write(2)`，
而 accepted socket 未设 `SO_NOSIGPIPE`。`SIGPIPE(13)` 的默认处置是**终止进程**，于是 test host
在全部断言都已通过之后被杀，runner 重启 host —— 而 workflow 仍然报 success。

证据（解码后的 simulator Unified Log，非 `.ips`）：

```
launchd_sim[5273]: [user/501/UIKitApplication:com.zhien.zenagent.ZenAgent[9bea][rb-legacy] [6766]:]
  exited due to SIGPIPE | sent by ZenAgent[6766], ran for 21299ms
runningboardd[5281]: [app<com.zhien.zenagent.ZenAgent>:6766] exited with context
  <RBSProcessExitContext| status:<RBSProcessExitStatus| domain:signal(2) code:SIGPIPE(13)>>
```

同次导出的 `001-UsageTrackingAgent-*.ips` 是 `EXC_BREAKPOINT (SIGTRAP)`，**与 test host 无关**，
按判定表不作为根因。

### commits / CI

| | |
|---|---|
| 诊断 | `c8fd18f` — 用 `log show --archive` 解码 Unified Log，替代 grep 二进制 |
| 修复 | `0ea1351` — accepted + listening fd 上设 `SO_NOSIGPIPE`（test-only） |
| 该任务当时的 CI | `35479084907` → **success**，**0 test-host restart**，单次连续运行 |
| **当前 CI（两条集成测试恢复后）** | `35490514213` → **success**（两个 job 均绿），`✔ Test run with 190 tests in 25 suites passed after 25.030 seconds.`，零失败、零跳过 |

### 最终测试规模 —— 190 declared = 190 started，0 disabled / skipped

**当前口径：25 个 suite、190 个 test，全部启动执行；无 disabled、无跳过。**

| 数字 | 出处（精确命令 / 日志行） |
|---|---|
| **190 tests in 25 suites** | `✔ Test run with 190 tests in 25 suites passed` —— 框架汇总；源码中同样有 190 个 `@Test`、25 个 `@Suite` 声明 |
| **0 skipped** | 两条集成测试已恢复；`grep -rn '\.disabled(' Tests/ZenAgentTests` 为空 |

两条恢复的测试在该次日志中的原文：

```
✔ Test "cancelling a provider consumer reaches the network without inventing a failure" passed after 0.023 seconds.
✔ Test "a connection that dies after data was observed is an interrupted stream that delivered data" passed after 0.010 seconds.
```

#### 历史：恢复之前的状态是 188 = 186 实际执行 + 2 disabled / skipped

以下**只描述恢复之前**，不再适用于当前。

| 数字 | 出处 |
|---|---|
| **188 tests in 25 suites** | `✔ Test run with 188 tests in 25 suites passed` —— 恢复前 |
| **186** | `grep -c '◇ Test "'` —— 实际启动并执行的 test 数 |
| **185** | `grep -oE '◇ Test "[^"]+"' \| sort -u \| wc -l` —— 这 186 次执行使用的唯一 display string 数 |
| **2** | `grep -c '➜ Test "'` —— 当时的两条 `.disabled` 集成测试 |

**186 次执行只有 185 个唯一 display string，并不是少执行了 1 个 test。** 两个独立测试分别
位于两个不同 suite，但刻意使用了同一个显示名：

- `DeepSeek provider` suite：`editedInstanceIsRefused`
- `DeepSeek streaming` suite：`editedInstanceIsRefusedBeforeDispatch`

二者的 display name 都是 `an edited instance is refused before anything is sent`，实测为：

```text
started lines : 186
unique names  : 185
duplicated    : [('an edited instance is refused before anything is sent', 2)]
```

所以当时的关系是：**188 declared/reported = 186 started/executed + 2 disabled/skipped**。

**另一个历史上的 `185` 出处**：它是 `35447236888` 那次 restart 的诊断重建值，即
**restart 前 92 + restart 后 93，零交集，合计 185**，不是此前误写的 `93 + 93`。
尾段另含 2 个 skipped，因此当时框架只报 `95 tests in 15 suites`。
这个 `185` 是对被 restart 切开的执行记录所做的重建，不是 suite 的完整规模。

### 当时未完成、现已完成

`LocalHTTPServer` harness 当时已存在并可用；**那两条 `.disabled` 的 integration test
当时尚未迁移到它上面**。二者已于后续迁移中恢复，见 `## Increment 5` 一节。

### follow-up：发布竞态（**已于后续修复**）

评审指出一个**真实但独立**的既有竞态：`accept()` 已返回、`clientFD` 尚未发布的那段窗口里，
`shutdown()` 会看到 `clientFD == -1`，随后 worker 才发布 accepted 并可能进入阻塞 `read()`。
本轮（SIGPIPE 修复）的 `setsockopt` 只是把窗口略微拉长，**没有引入也没有修复**它。

**该竞态已在 `f567cbe` 密封**：`closed` 检查与 `clientFD` 发布合入**同一把 lock 的同一转换**，
shutdown 要么看到已发布的描述符并释放它，要么赢下竞态而 worker 放弃该描述符。
并附了一条**确定性**回归（test-only hook 停在 `accept()` 与发布之间），不依赖压力循环。

### 不变量

`App/` 未改；未改任何 timeout / retry / budget。

（本节当时还写着「两条 `.disabled` 集成测试未启用、未修改」—— 那是当时的事实。
二者已在后续迁移中恢复，见 `## Increment 5`。）

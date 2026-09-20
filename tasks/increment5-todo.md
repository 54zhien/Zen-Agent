# Stage 1 · 前置修复 + Increment 5（Streaming）执行清单

> 本文件是**当前增量**的活清单。
> `tasks/todo.md` 是 Stage 0 的历史记录（含 Review 段），**不被覆盖**。

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
- [ ] 两条 disabled 集成测试**尚未迁移**到 localhost harness（见下）

### 仍未完成：两条集成测试尚未迁移

`LocalHTTPServer`（test-only localhost HTTP/1.1 fixture）**已经存在并通过 CI**：
`LocalHTTPServerCharacterisationTests`（增量交付 / `bytes.task.cancel()` → peer close）
与 `LocalHTTPServerLifecycleTests`（4 条 teardown 断言）全绿。

`URLProtocolCharacterisationTests` 证明的是**旧桩**的局限：自定义 URLProtocol 驱动
`bytes(for:)` 时，少量 didLoad 后保持 request open 无法可靠交付给 consumer。
（**这是那个 harness 的观测，不推广到真实 HTTPS**；未测阈值。）

因此以下两条**仍是 `.disabled`，尚未迁移到 `LocalHTTPServer`**：

| 测试 | 需要的 server 行为 |
|---|---|
| `URLSessionHTTPTransportTests.failureAfterObservedDataIsInterrupted` | 发 partial → consumer 收到 → 触发 close |
| `StreamingCancellationTests.cancellationReachesTheNetworkWithoutAFailure` | 发合法 SSE → consumer 收到 → stall → cancel |

迁移后按方案要求**重新启用或等价替代**。
**不要改 production `URLSession.bytes(for:)`**，也不切 delegate。

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

## Review（增量结束时填）

_待填_


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
| 最终 CI | `35479084907` → **success**，**0 test-host restart**，单次连续运行 |

### 最终测试规模 —— 四个数字，各自出处，差额未解释

**这四个数字互不相等，且我没有把它们对齐。** 每个的来源如下，不做推断：

| 数字 | 出处（精确命令 / 日志行） |
|---|---|
| **188 tests in 25 suites** | `✓ Test run with 188 tests in 25 suites passed` —— **框架自己报的总数**，不是执行数 |
| **186** | `grep -c '◇ Test "'` —— **starts 行数**（同名可重复，见下） |
| **185** | `grep -oE '◇ Test "[^"]+"' \| sort -u \| wc -l` —— **唯一测试名个数** |
| **2** | `grep -c '➜ Test "'` —— 两条 `.disabled` 集成测试，名字分别是 `a connection that dies after data was observed...` 与 `cancelling a provider consumer reaches the network...` |

**186 与 185 的差额是实测出来的，不是推测。** 在 `35480007880` 的日志里：

```
started lines : 186
unique names  : 185
duplicated    : [('an edited instance is refused before anything is sent', 2)]
```

唯一被重复 start 的名字是 `an edited instance is refused before anything is sent`（2 次）。
**此前我在这里写的「参数化测试同一名字会出现多行」是未经证实的推测，已删除。**

**188（框架自报总数）与 187（185 unique started + 2 skipped）之间差 1，来源未核实，
不编造解释。**

**历史 `185` 的出处必须纠正**：它是 `35447236888` 那次「restart 前 93 + restart 后 93，零交集」
的重建值 —— 且那次日志实为 `92 + 93`（不是 `93 + 93`），尾段另含 2 skipped，
故当时框架只报 `95 tests in 15 suites`。它是**诊断用的重建值**，不是 suite 的完整规模。

### 未完成（本任务边界之外）

`LocalHTTPServer` harness **已经存在并可用**。未完成的是：
**那两条 `.disabled` 的 integration test 尚未迁移到它上面并重新启用。**

### follow-up（本轮未改代码）

评审指出一个**真实但独立**的既有竞态：`accept()` 已返回、`clientFD` 尚未发布的那段窗口里，
`shutdown()` 会看到 `clientFD == -1`，随后 worker 才发布 accepted 并可能进入阻塞 `read()`。
本轮的 `setsockopt` 只是把窗口略微拉长，**没有引入也没有修复**它。
正确封法是让「检查 closed + 发布 accepted」在同一把 lock 下完成。

### 不变量

`App/` 未改；两条 `.disabled` 集成测试未启用、未修改；未改任何 timeout / retry / budget。

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
| 5D+5F | Timeout 分层 + Base URL 单真值 + 桩串行修复 | `35435945399` 跑中 |
| 5E+5G | 真取消 + 分类收尾 | 待推 |

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
- [ ] **CI 全绿**
- [ ] 汇报 10 项，**停在 Increment 5 边界**

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

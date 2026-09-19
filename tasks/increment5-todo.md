# Stage 1 · 前置修复 + Increment 5（Streaming）执行清单

> 本文件是**当前增量**的活清单。
> `tasks/todo.md` 是 Stage 0 的历史记录（含 Review 段），**不被覆盖**。
> 完整计划与依据见会话 plan 文件；Blueprint 引用已逐条核实。

**纪律**：小步提交 → 每步 CI 验证 → 增量结束停下等确认。CI 失败即停下重新规划，不硬推。
**推送**用 `if git push` 判断，不用管道（handoff `:61`）。

---

## 前置 P：冻结完整 Credential Binding Identity

漏洞已核实（非采信）：seed 无 reference · `attachCredential` 不 bump revision ·
`FrozenConfiguration` 取当前 instance 的 reference 只比 generation。

- [x] P1 `CredentialBindingSnapshot { reference, generation }`
- [x] P2 `RequestConfigSeed.credentialBindingRevision: Int` → `credentialBinding: CredentialBindingSnapshot`
- [x] P3 validate 同时验 reference 与 generation
- [x] P4 删 `saveProviderInstance` → `createProviderInstance`（已存在即抛）+ `private updateProviderInstance`
- [x] P4b `attachCredential` **不** bump revision（identity 由 seed 显式冻结，不间接依赖别的 revision）
- [x] P5 更新 8 处测试调用点 + `SecretContainmentTests` 断言改为「含 reference id、不含 secret」
- [x] P6 新 `PersistenceError.providerInstanceAlreadyExists`
- [x] P7 新 suite `FrozenCredentialIdentityTests`（A refresh / A rebind / **A→B 同 generation** / detach / logout / seed 无 secret / create 拒绝覆盖）
- [ ] **CI 绿**（run id: ______）

**P6 存储兼容性**：seed 形状变更使已存 seed 无法解码。pre-release、无线上数据 → 干净切断，
**显式决定，非疏忽**。

---

## Increment 5A：Streaming HTTP Transport

- [ ] `HTTPTransport.stream(_:) -> AsyncThrowingStream<Data, Error>`（incremental bytes）
- [ ] `HTTPTransportError` + `.httpStatus(HTTPResponse)` / `.inactivityTimeout` / `.streamInterrupted(deliveredData:reason:)`
- [ ] `URLSessionHTTPTransport.stream` 实现：非 2xx 从**同一条流**读完 body，绝不重发
- [ ] 只有一处穷尽 switch（`DeepSeekProvider.swift:165`）已更新
- [ ] `FakeHTTPTransport` 补 `stream`
- [ ] **CI 绿**（run id: ______）

## Increment 5B：SSE Parser（独立纯逻辑）

- [ ] `SSEParser` / `SSEEvent` / `SSEStreamElement` / `SSEParserError` / `SSEParserLimits`
- [ ] 字节层行缓冲，行边界确认后才解码 UTF-8
- [ ] `[DONE]` → `.done`；其后字节忽略；`finish()` 未见 `[DONE]` 即抛 `unterminatedStream`
- [ ] 有界缓冲（Blueprint `:61` 自己留的空洞）
- [ ] `SSEParserTests` 全矩阵：chunk 边界 / 拆 UTF-8 / 拆 JSON / `\n` `\r\n` `\r` / 空行 / 多行 data / comment / `[DONE]` / 多 event 同到 / 一 event 多次到 / 非法 UTF-8 / EOF before `[DONE]` / `[DONE]` 后数据
- [ ] **CI 绿**（run id: ______）

## Increment 5C：DeepSeek streaming wire format

- [ ] `stream: true`，仍不发 capability options
- [ ] `DeepSeekStreamChunk` DTO（不出 adapter 目录）
- [ ] 「无 text delta」不判 malformed；末 chunk 可只有 finish_reason；usage 在 `[DONE]` 前
- [ ] **不做** Increment 6 的 normalization
- [ ] **CI 绿**（run id: ______）

## Increment 5D：Timeout 拆层

- [ ] `StreamTimeoutPolicy`（transportInactivity / firstEvent / betweenEvents / checkInterval）
- [ ] transport liveness 在 `URLSessionHTTPTransport`；语义进展在 adapter
- [ ] **关键测试**：只发 keep-alive 超过 firstEvent → transport 不超时、adapter 必须超时
- [ ] `ProviderError` + 3 case，`retryDisposition` 按 Blueprint 表
- [ ] **CI 绿**（run id: ______）

## Increment 5E：真正的 Cancellation

- [ ] `StubURLProtocol` 记录 `stopLoading`
- [ ] 证明 `Task.cancel()` → 消费停止 → URLSession task 真取消 → `ProviderError.cancelled` → 后续不再交付
- [ ] **CI 绿**（run id: ______）

## Increment 5F：Base URL 单一真值

- [ ] 一个 `resolveBaseURL(for:)`，stream 与 non-stream 共用
- [ ] 删 `DeepSeekProvider.baseURL` 属性与 init 参数
- [ ] 测试：自定义 endpoint 下两条路径都走 custom、无请求打到官方 URL
- [ ] **CI 绿**（run id: ______）

## Increment 5G：错误与断流分类 + 收尾

- [ ] 分类矩阵全测（见计划表）
- [ ] 新增 CI hygiene：DeepSeek DTO 只在 adapter
- [ ] `/code-review` 跑 diff，修问题
- [ ] **CI 绿**（run id: ______）
- [ ] 汇报 10 项，**停在 Increment 5 边界**

---

## Review（增量结束时填）

_待填_

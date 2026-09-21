# 交接：Zen Agent 当前开发进度

> 写给下一个会话。**先读这一份，再读 `tasks/todo.md` 和 `tasks/stage1-plan.md`。**
> 写于 2026-09-19。
>
> 状态：**历史交接快照（2026-09-19）。Stage 1 已完成；最终实现与证据见 `tasks/stage1-closure.md`。**
> 下文保留当时的 HEAD、CI、测试数和下一步记录，不代表当前仓库状态。

---

## 0. 三十秒版本

原生 iOS 多 Provider Agent 客户端。**Stage 0 已完成，Stage 1 进行到 Increment 4**。
代码在 `C:\Users\Azusa\Desktop\Zen-Agent`，设计蓝图在 `C:\Users\Azusa\Desktop\Zen Agent`（仓库 `Zen-Agent-Blueprint`）。

| | |
|---|---|
| 当前 HEAD | `a9c7094` |
| 最近 CI | run `35433272387` → **success** |
| 测试 | **103 条 / 14 个 suite**，全绿 |
| 代码规模 | `App/` 26 个 swift 文件，`Tests/` 17 个 |

**下一步是 Stage 1 Increment 5：SSE Streaming transport。** 用户按增量逐个确认，每个增量结束就停。

---

## 1. 两个仓库的关系

```
Zen-Agent-Blueprint（设计，@6b12e46）        Zen-Agent（代码）
  Design/ 13 份笔记 + CONTEXT.md + ADR/        App/ Tests/ Docs/ADR/ tasks/
```

**单向**：Blueprint 定义意图，代码发现现实。冲突时 → 验证事实 → 说明冲突 → 实现更安全方案 → **更新 Blueprint** → 必要时记 ADR。不让代码悄悄偏离，也不改 Blueprint 去迁就代码。

**ADR 分两处**：产品/安全/设计决策在 Blueprint 的 `Design/ADR/`；工程/工具/实现决策在代码仓库的 `Docs/ADR/`。代码仓库现有 0001（GRDB 选型）、0002（XcodeGen）、0003（Keychain accessibility）。

---

## 2. 这个项目怎么干活（最重要的一节）

用户的工作方式很明确，破坏它的成本很高：

- **小步 + 每个增量 CI 验证后再进下一个。** 不要一次做完一个 Stage。
- **每个增量做完就停**，报告后等确认。不要自行开始下一增量。
- **绝不在未编译的情况下声称完成。** 本机没有 Swift 工具链，**CI 是唯一的验证手段**。说"应该能编译"等于没说。
- **报告要区分「已核实」与「推断」。** 这个用户会追问来源。本会话被纠正过三次，都是因为我用了记忆里的平台知识下结论。
- **不要过度抽象。** 明确禁止：通用插件框架、`AnyProvider` 类型擦除层、DI 容器、为"将来可能换 Provider"留的抽象。
- **测试要断言正确行为，不是描述代码做了什么。** 有两处真 bug 是这样抓到的（见 §6）。

### 报告格式（Increment 结束时用户会点名要的）

用户给出的明确清单：增量做了什么 / 关键决策及理由 / 新测试数量 / 仍未解决且留给后续增量的问题。

---

## 3. 环境坑（每个都花过一次 CI 轮次）

| 坑 | 事实 |
|---|---|
| **仓库必须保持 public** | private 时连续 5 次 `runner_name: ""` + `steps: 0`——**job 从未被分配机器**。不是代码问题。改 public 后立刻恢复。 |
| 网络会断 | 用户在用代理工具（`github.com` 解析到 `198.18.0.149`，是 fake-IP）。推送可能 TLS 失败，重试即可。 |
| 无本地工具链 | Windows，无 Swift/Xcode。`xcodegen` 也不能跑。只能静态检查 + CI。 |
| 验证推送结果 | **不要用 `git push \| tail`** —— 管道吞掉退出码，会误报成功。用 `if git push`。 |

---

## 4. Swift 6 严格并发：本会话踩过的编译错误

这些是**每次都会遇到**的，记下来省 CI 轮次：

```
1. @Sendable 闭包不能捕获可变 var
   → 先 `var x = ...; x.y = ...` 再 `let x2 = x`，闭包捕获 x2

2. NSLock.lock()/unlock() 在 async 上下文不可用
   → 用 lock.withLock { }。非 async 方法里仍可用裸 lock()

3. Sendable conformance 必须和类型在同一个文件
   → 若协议继承 Sendable（如 CredentialMetadataRepository），
     conformance 不能写在别的文件的 extension 里

4. 枚举有多个关联值时，case .x(let a) 会绑定整个元组
   → 用 case .x(_, let a)

5. 闭包/工厂里的参数不能用 `try #require` 嵌套 try
   → 用 guard + Issue.record + return
```

---

## 5. CI 强制的边界（写在 `.github/workflows/ci.yml` 的 repo-hygiene job）

这些不是文档约定，是**每次 CI 都会失败的检查**：

| 规则 | 为什么 |
|---|---|
| `import GRDB` 只在 `App/Persistence/` | 存储引擎不得进入 Runtime/UI |
| `import Security` 只在 `App/Credential/` | 调用方走 `CredentialStoring`，不直接摸 Keychain |
| `URLSession` **仅代码**（忽略注释行）只在 `App/HTTP/` | 重试/超时/取消策略只有一个家 |
| `SecretValue` 不得变成 `Codable` | 见 §6 |
| `.xcodeproj` 不入库 | XcodeGen 生成 |
| 签名物料被忽略 | 8 种模式 |
| 该入库的文件没被误伤 | 含 `Docs/ADR/0001` |

**`App/Provider/` 不 import GRDB 也不 import Security——它是纯领域层。**

---

## 6. 已经建立的核心不变量与陷阱

### 结构性保证（不是靠约定）

- **`SecretValue` 不是 `Codable`** → "Secret 进不了 GRDB / 进不了 RequestConfigSeed" 是**编译期性质**。
- **`SecretValue` 和 `HTTPRequest` 都有 `customMirror`** → 光有好听的 `description` 挡不住反射。`String(describing:)` 会走进字段。
- **active Parent Run 唯一性由 partial unique index 保证**，`WHERE activeSlot IS NOT NULL AND kind = 'parent'`。store 里的预检查**只是为了错误信息**，不是保证。

### 本会话抓到的两个真 bug（都值得知道其形状）

1. **`undoDeletion` 没有状态守卫** —— 对已 finalize 的会话撤销会把 lifecycle 翻回 `visible` 而正文已删。
   我当时的第一个念头是**写测试记录这个行为**——那会把缺陷固化成设计。**改成修实现**。
2. **`HTTPTransportError` 从 adapter 漏出** —— 调用方拿到传输层类型，正是 seam 存在的意义所在却在 seam 上漏了。
   抓到它的是两个**我按正确行为写的测试**，而不是按代码实际行为写的。

**共同点：测试写的是"应该怎样"，不是"现在怎样"。**

### 已核实的平台事实（不要凭记忆重新下结论）

- **Keychain**：`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`。iOS 26 **没有**新的 Keychain accessibility API。
  `errSecInteractionNotAllowed` **不等于** `errSecItemNotFound`——**删除在读取失败时仍然成功**，混淆两者会在后台启动时删掉有效 token。见 `Docs/ADR/0003`。
- **DeepSeek**：`https://api.deepseek.com` + `POST /chat/completions`；当前模型 **`deepseek-flash`** 和 **`deepseek-v4-pro`**；
  `deepseek-chat` / `deepseek-reasoner` **已退役**，官方 model 列表里根本不出现；`reasoning_effort` 取值是 `low/high/max`；思维链在 `reasoning_content`。
- **GRDB 7.11.1**：`DatabaseQueue` 是 `@unchecked Sendable`；`read`/`write` 有同步（无 Sendable 约束）和 async（要求 `T: Sendable`）两个重载；**同步重载内部持锁**——async transport 里调它会阻塞，Increment 5 要注意。

---

## 7. 当前代码地图

```
App/
├── HTTP/            HTTPRequest（自我遮蔽）/ HTTPResponse / HTTPTransport / URLSessionHTTPTransport
├── Credential/      SecretValue / CredentialStore(领域规则) / SecretBackend / KeychainSecretBackend
├── Provider/        纯领域层，两个 backend 都不 import
│   ├── ProviderTypes / RequestConfigSeed / ModelProvider / ProviderAvailability
│   ├── ProviderError（含 RetryDisposition）/ ProviderResponse / FrozenConfiguration
│   ├── FakeProvider.swift
│   └── DeepSeek/    DeepSeekProvider / DeepSeekDTO（DTO 不出这个目录）
└── Persistence/     GRDB 唯一入口。Migrations v1–v4，Records，PersistenceStore + 5 个 extension
```

**Schema 版本**：v1 初始 / v2 agentStep / v3 credentialBinding / v4 providerInstance。

**测试 suite（14 个）**：Atomic send commit · Active parent run uniqueness · Agent step attempts ·
Conversation deletion · Indeterminate tombstone · Migration · Streaming persistence ·
Tool dispatch recovery · Credential store · Secret containment · Provider instance ·
Provider availability · DeepSeek provider · Stage 0 smoke。

---

## 8. Stage 1 的剩余增量（用户已给的划分）

| # | 内容 | 状态 |
|---|---|---|
| 1 | Conversation/Message/Part 与 Persistence 对齐 | ✅ 完成 |
| 2 | CredentialStore / Keychain 边界 | ✅ 完成 |
| 3 | Provider / ProviderInstance / ModelDescriptor + Fake | ✅ 完成 |
| 4 | DeepSeek Transport（非流式） | ✅ 完成 |
| **5** | **SSE Streaming transport** | ⬅ **下一步** |
| 6 | Streaming event normalization | |
| 7 | ModelDescriptor / capability | |
| 8 | 最小 PromptComposer | |

**Stage 1 Gate**（Blueprint 原文）：通过 Provider/Repository 的最小 harness（**不要求完整 AgentRuntime**）能用 **fake + DeepSeek** 完成稳定文本 Streaming，并**重启后恢复已保存 Conversation**。

### Increment 5 的范围（用户已列）

SSE transport、partial event assembly、UTF-8 / malformed event、inactivity timeout、HTTP failure、cancellation、**禁止危险的自动重试**。

---

## 9. 仍未解决、明确要留给后续的问题

**Increment 5 之前该补的**（我在 Increment 4 报告里提过）：

1. **`ProviderInstance.baseURL` 没接通。** `DeepSeekProvider` 用的是自己的默认值，**没读实例上可编辑的 endpoint**。实例 endpoint 的语义（`Provider 与模型.md:49`）现在是悬空的。
2. **没有超时配置。** `URLSessionHTTPTransport` 用默认值，而默认 `timeoutIntervalForRequest` 的语义是**数据到达间隔**（60s）——非流式勉强可用，**SSE 下会直接掐断长 reasoning 静默期**。这是 Increment 5 的第一个产物。
3. **`HTTPTransport.send` 一次性返回完整 body**，不能流式。SSE 需要另一个形态——加 `stream(...)` 还是新协议，取决于 Increment 5 看到的真实需求。
4. **取消没有被真正测试过。** 现在测的是"transport 抛 `.cancelled` 时 adapter 的映射"，**没测 `Task.cancel()` 是否穿透到 URLSession**。

**更远的**：

5. `RetryDisposition` 无人消费——它是给更高层的，而更高层（AgentRuntime）在 Stage 2。
6. 模型列表没有远端来源，`DeepSeekProvider.modelIDs` 是硬编码的当前模型。Blueprint 要的"远端 > 内置 > 手动"未实现。
7. `CredentialKind` 只有 `apiKey`——OAuth 的 access/refresh 对没有建模（Stage 11 第二个 Provider 时）。
8. credential 与实例是**多对一还是一对一未定**。`安全与权限.md:53` 提到"删除引用方前先检查 reference 是否共享"——**共享是可能的**，跨实例共享的撤销语义没有设计。
9. `EndReason.credentialExpired` 与 `ProviderAvailability.authenticationRequired` 的对应关系未定（Increment 4 起就在，仍未解决）。
10. 「凭据暂时不可用」在 UI 上如何呈现未定——取决于 `Provider 与模型.md` 的 `unavailable` / `re-authentication` 状态设计。
11. **换机后凭据不存在**（`ThisDeviceOnly` 的设计后果）。**这必须写进用户可见说明**，目前只在 ADR 里，没有归属到任何 Stage。
12. Keychain 项在 App 卸载后仍会留存——影响"全新安装"和"All Local Data 是否真的干净"。

---

## 10. Blueprint 侧待办（属于设计仓库，不是代码仓库）

- Blueprint 仍写着「不提前拍板 SwiftData 还是 GRDB」（`消息与数据.md:457`、`工程与发布.md:290`），而 Stage 0 已选定 GRDB。按单向回写流程，**Blueprint 应被更新**。
- `消息与数据.md:469` 与 `开发规划.md:278` 对「Run execution snapshot 归属哪个 Stage」口径不一致。我在计划里的读法是：**AgentStep/Attempt 的记录属 Stage 1，snapshot 的内容与使用属 Stage 2**——已按此实现，但 Blueprint 未回写。

---

## 11. 常用命令

```bash
cd "C:/Users/Azusa/Desktop/Zen-Agent"

# 看 CI
gh run list --limit 3
gh run view <id> --log-failed | grep -E "error:|✘ Test" | head -20

# 本地能做的静态检查（唯一能离线验证的东西）
python -c "import yaml; yaml.safe_load(open('project.yml'))"
python -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))"
grep -rl "import GRDB" App --include="*.swift" | grep -v '^App/Persistence/'
grep -rl "import Security" App --include="*.swift" | grep -v '^App/Credential/'
grep -rn "URLSession" App --include="*.swift" | grep -v '^App/HTTP/' | grep -vE ':[[:space:]]*(//|///|\*)'
```

**提交信息**结尾加：
```
Co-Authored-By: Claude Code <noreply@anthropic.com>
```

---

## 12. 一句话提醒

**这个项目的价值不在"代码写得多"，而在"每一条断言都有证据、每一条边界都被 CI 强制、每一个未解决的问题都被明确记下来而不是被掩盖"。**

如果下一个会话要在"快速推进"和"保持这个标准"之间选，**选后者**。用户已经明确说过：环境失败不能被读成代码通过，也不能被读成代码失败；测试要断言正确行为而不是描述现状。

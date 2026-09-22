# I09 — Stage 2 Gate 与收口

**将调用**：`/zh-code-reviewer`（对本次新增的 Gate 测试做中文审查，作为「非琐碎代码改动完成前至少一个 skill」的那一次；用户全局规则里中文报告优先于内置 code-review）。
其余 skill 无一匹配：`apple-design`/`frontend-design`/`dataviz`/`agent-browser`/`perf-profiler`/`run` 都是 UI、浏览器、图表、性能或跑 App 的方向，本任务是纯 XCTest/swift-testing 集成验收；`security-review`/`simplify` 不适用于只写测试文件的改动。`grilling` 是拷问方案，本任务明确「不做方案、不重新设计」。

## 性质
Stage 2 收口 Gate：对已逐增量证明过的 contract 做整合验收，不是新生产 contract。**不写 RED probe**。
优先只写测试；只有断言暴露真实生产缺口才补生产代码，并单列。

## 交付物
- `Tests/ZenAgentTests/Stage2GateTests.swift`（Suite：`Stage 2 closure gate`）
- `Tests/ZenAgentTests/Stage2RuntimeFixtures.swift`（磁盘 fixture + 脚本化 provider + 阻塞 stream box + dispatch gate）
- `Tests/ZenAgentTests/Stage2SideEffectTool.swift`（最小补充：可选阻塞 gate；默认 nil，I08 行为不变）

## 已确认的既有事实（读代码得到，不是猜的）
- `CalculatorTool` 用 `String(value)` 渲染 Double：`6*7` → `"42.0"`，已被 `ToolRegistryTests` 用 `"1 + 2 * 3" == "7.0"` 钉死 → Gate A 断言 `"42.0"`（规格里的 `42` 是简写）。
- `StreamingAccumulator` 有私有 1024 字节阈值，短 delta **不会**在 streaming 期间落库，只在 flush（完成/取消/失败）时落库 → Gate B 不能「等 partial 落库后再 stop」，只能等**已落库的 open part**，见报告。
- `Stage2SideEffectTool.descriptor.approvalRequirement == .required` → Gate C 必须走真实 approval 路径才会 dispatch。
- `ToolRuntime.executePrepared` 先 `markToolCallDispatched` 再进 executor；`finishDispatchedToolCall` 就是迟到完成要输的那个 CAS。

## 清单
- [x] 读 `App/Runtime/`、`App/Tool/`、`App/Persistence/`、既有 fixture 写法
- [x] 写 `Stage2RuntimeFixtures.swift`
- [x] 最小补充 `Stage2SideEffectTool.swift`（可选 gate）
- [x] Gate A：`user model tool model closes one parent run`
- [x] Gate B：`stop cancels the run without accepting late provider output`
- [x] Gate C：`recovery never repeats a dispatched side effect`
- [x] Gate D：`a completed run is fully recoverable after the database is reopened`
- [x] 本机能跑的自检（repo-hygiene 静态检查 / 括号结构自检 / 重复类型名自检）
- [x] 提交 + 推送 `origin/feat/s2-i09-stage2-gate-closure`
- [x] 报告

## Review
见最终 stdout 报告。

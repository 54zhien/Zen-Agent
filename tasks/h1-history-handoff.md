# H1 — 历史读取与 Preview 接管

状态：PR [20](https://github.com/54zhien/Zen-Agent/pull/20) 开发中，未合并。
完整 GREEN、独立整分支 review、主线 tree 核对及真机 Gate A 尚未关闭。
H1 是 S5-04 后的维护修复；S5-05～16 未在本分支实施。

## 依据与范围

- 实际基线：`70c5c17c330abffaf65aa14365f796c1453c0d60`，tree `1791005415034b3522b1c81563b105b84c8075da`。
- 基线 CI `36466689960` 成功；S5-04 已合入 main。
- Blueprint：`596a84d4b58769e3e7b838be95edcb43f9e0ec82` 的开发规划、CONTEXT、消息与数据、App Space/Split/全局导航。
- 用户提供的 `Zen-Agent-Review-and-Stage5-Plan-2026-09-29.md` 中 H1/F1/F2/F3 为本次修复契约。
- 没有修改 schema、依赖、签名或 IPA 流程；Runtime 继续拥有 Run/Streaming/Approval，Session 继续拥有草稿与阅读状态。

## 读取与接管合同

Persistence 在一次只读事务中执行 8 条会话范围查询，返回 Sendable 记录快照。
查询数不随 Turn 数增长；完整历史的字节数与投影构建成本仍随历史增长。
SQL 用 join 限定范围，避免逐 Run 查询和大 ID 参数数组。
Conversation 只负责从快照构建纯投影，GRDB 不越过 Persistence。

Router 持有一个 `ConversationHistoryPreparation`，Open、Return、启动恢复和生产重载共用它。
保留工作 Task 的句柄，传播取消；旧工作结束后才启动最新请求。
GRDB 7.11.1 原生异步 read 负责队列、隔离和取消；没有手动跨线程使用连接。
同步投影构建前后检查取消，不承诺任意同步 SQL/CPU 工作瞬时停止。
新导航用已准备快照检查 lifecycle，避免先同步查询并等待旧读取队列。
旧 Pane/Preview 在新内容登记成功前保持可见。

仅在 preparation ticket 存续时保留临时 durable-event 日志。
连续同 Part 的 Delta 合并；文本更新不使 ticket 失效，Run/Tool 结构变化需新快照。
日志上限为 256 KiB / 512 个事件，是工程接管预算；超限显式失败并保留 Preview。
持久化 UTF-8 字节偏移作为重放下界，跳过已有字节，只追加合法的缺失后缀；空洞或非法边界要求恢复。
Part 完成和 Run 结束保留顺序，接管登记不再同步读取完整历史。
`lastHandoffDuration` 留作设备测量入口，不代表已完成性能验收。

## RED 回执

1. `2b36612234937bf841f71c7fa5c0ff287cae2470`：CI `36518753308` attempt 1 / job `109247008661`。
   应用构建成功；731 Swift Testing / 111 suites 中只有查询预算的 2 个问题：100 Turn 为 302 SELECT，1000 Turn 为 3002 SELECT。
   20 XCTest、14 UI 通过；只有一次 Swift test-run start，无宿主重启。
2. `0fb4f208195a43d51783215aca801980ccac1390` 的补充 CI `36519814815` 因 fixture 缺少必填 ID 而编译失败。
   修正于 `0f133aae` / `fafb116e`；该编译失败不计行为 RED。
3. tests-only `fafb116e21864da4e413b700c5b9e62f5f771532`，tree `8e5284a24ec06650404f58de2632a6cb3179c37b`：
   CI `36520183013` attempt 1 / job `109251340699`，应用构建成功。
   735 Swift Testing / 111 suites，12 个问题均来自新回归：取消后的 5 SELECT（3 次）、持续 Delta 时 Return 失败、WAL 快照混读、查询预算、中文/emoji 部分重叠增量。
   20 XCTest、14 UI 通过；一次 test-run start，无宿主重启。

之后的 queued-navigation 计数与 terminal-during-read 控制测试是新异步 API 的补充验收。
计数 API 本身不能在实现前运行，作为明确的脚手架例外记录；不把缺符号或编译失败当作 RED。
原有 native editor release、pending Send、late failure、阅读锚点、离线历史及活跃 Run/Approval 回归继续运行。

## 后续顺序与用户裁决

H1 完整 CI/review/主线核对 → H2 错误来源及摘要行级隔离 → 对应构建的 Gate A 补证 → S5-05～16。
设备条目始终单列，模拟器不能代替真机验收。

2026-09-29 当前聊天中用户裁定：

- S5-07 Undo 窗口 **10 秒**。实施前明确持久 deadline、冷启动和时钟合同。
- S5-08/09 允许 Split Lift 回 App Space；保留 Split 布局供恢复。

两项裁决须在相应切片实施前同步 Blueprint；本 H1 不添加其生产代码。

## 第一轮源代码 CI：未通过

`6a4569b01c33523592591a52cfd6886b0f2d1c7e`，tree `2e8e9c4355ffea826b00f7ebc6300eb62b2ef673`：
CI `36522290295` attempt 1 / job `109257915770`，应用构建成功，736 Swift Testing / 111 suites 和 20 XCTest 通过。
14 UI 中同一阅读锚点用例的 2 个断言失败；无宿主重启。对应 PR CI `36522295940` 复现同一失败。

两份日志均在 Lift 前已有 offscreen anchor：offset=0，正文锚点 minY=1204，却收到定位完成。
深层定位回归正常。异步 Open 后 ConversationPaneView 沿用旧空页的 SwiftUI 滚动状态及测量。
按 Conversation ID 重建原生内容，保留既有 UI 断言及 3px 容差；待下一次真实 CI 验证。
新增 completed-snapshot/late-Start 和 idle-shell/route-release 行为探针，先观察实际失败，后修对应行为。

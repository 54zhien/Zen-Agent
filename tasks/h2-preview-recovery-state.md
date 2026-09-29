# H2 — Preview 错误来源与摘要行级隔离

## 范围与基线

执行来源：2026-09-29 用户提供的 Stage 5 评审方案 F4/F5/H2。
用户确认顺序：合并 PR #20 → H2 → 对应新构建的真机 Gate A → S5-05。
后来粘贴的 Card Browse / Snap 方案作为 S5-05 范围依据，不跳过本切片或设备门。

H1 已集成到 `main@3505a2e6ed4bf85f59cdbff41403f4ea79d47093`，
tree `0ae121074912a745c26602e92c6445796a1d9b66` 与最终 H1 测试源码相同。
主线 CI `36531208778` attempt 1 / job `109285116808`：generation、应用构建、hygiene 通过；
740 Swift Testing / 111 suites、20 XCTest、14 UI 全通过，一次实际 Swift test-run start，无实际宿主重启。

分支 `codex/s5-preview-recovery-state`；独立 PR #21。
复用已有受管理工作树，主桌面 checkout 只在干净 main 上 fast-forward。

## 行为合同

- 刷新失败与 Return 失败是独立来源；展示消息由来源事实推导。
- 刷新成功只清除摘要读取错误，不清除先前 Full Return 错误。
- Return 成功清除自己的失败；准备中展示 restoring；取消不伪装为存储失败，不发布旧结果。
- 全局摘要读取失败保留上一次可读结果，继续明确报错。
- 未知 RunState/EndReason 若可定位到一条摘要，保留其 ID、可读标题、摘录、游标和顺序。
  将该条标为不可用，Run projection 留空，不能假设 completed、ready 或其他结束原因。
- 不可用 Current Card 同时提供视觉与无障碍提示；真实 Full Return 读取错误仍可见。
- 不改变 Runtime/Stop、Session、Pane、持久化或历史加载工作所有权。

## 测试先行

测试采用现有 API 和真实持久化结构，不用缺失类型制造 RED：

1. 真实摘要 SQL 失败、恢复表、更新标题、刷新成功后错误消失。
2. Full Return 失败后，摘要刷新失败或恢复成功均不能抹除其错误；随后成功 Return 清除旧错误。
3. 仅取消调用者 Task，Preview/Session 保留且可重试，无新增存储错误。
4. 52 条真实历史形成首屏 49 好行 + 1 坏行并有下一页；未知 state/endReason 各验证页面与四 ID window，
   ID/title/excerpt/cursor、健康行、下一页排序保持。
5. 摘要坏行标为不可用并可播报；对应 Full Return 的实际读取失败仍通过 status 和 accessibility message 显示。

保留既有全局数据库故障、坏 JSON/正文披露边界、分页/查询预算、native-editor 释放、Session/取消接管、锚点和 Runtime/UI 回归。
首个 tests-only `889fbdb` 的 build 尚在排队时加入无障碍断言并发布 `4f70e6c`；被替代的排队运行不算行为 RED。
编译或 fixture 错误也不算行为 RED。

实际 RED：源码 `4f70e6c8ab11e36ca7a4114b9494df56eb28370f`；PR merge
`dcb3ff6b4bd18cef5af97f13d1fb5615663f5eaa`。实际 fetch 后二者 tree 均为
`f368404822a6da1e40da4287c3cbd8505a2dea15`。
PR CI `36532649896` attempt 1 / job `109289796012`：generation、应用构建和测试编译成功。
744 Swift Testing / 111 suites 运行后出现 12 个预期问题：刷新错误残留、Return 错误被刷新覆盖、
取消伪报错、未知元数据使整页失败、当前不可用状态与播报缺失。
20 XCTest、14 UI 全通过；一次实际 Swift test-run start，无实际宿主重启。

对应最小源代码修改：Preview 的摘要失败事实与 Return 失败事实分开，status/accessibility message 统一派生；
接受当前 preparation ID 才进行取消清理；Persistence 的未知元数据仅标记该行不可用，SQL 失败继续抛出。

## 实现边界

采用现有 summary 的 contentUnavailable 与可选 runProjection，不复制 Run 状态机，不新增摘要数据库、迁移或依赖。
消息派生与操作代际归 Preview owner；SQL/全局读取失败保留 Persistence 错误边界。
诊断不复制正文、未知原始值或 Secret。

F4 中 Open Bool 的“逐步收敛”在实际 S5-05 导航交互中再决定；本切片验证 Full Return 的错误可见，
不宣称已新增 Recent/Open 失败 UI。若具体审查发现要求扩展，会先记录行为 RED。

## 验收记录

实际 RED/GREEN run、attempt、head/tree、测试数量与独立整分支审查维护在 PR #21；
未取得真实完整 CI 之前不宣称 H2 完成。
真机 Gate A、中文/emoji 输入选择、触摸/无障碍、Instruments/主线程耗时、内存和舒适度继续待验收。
未新增 IPA、签名流程或 S5-05/后续功能。

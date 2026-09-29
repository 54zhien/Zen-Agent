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

独立整分支审查将 Recent/Open 的真实读取失败仍然静默列为 Important，已接受。
Open Bool 的完整类型化重构仍可逐步演进；本 H2 必须提供实际 Full Open 失败反馈。
Recent 的列表读取与 Full Open 失败独立保存，展示消息派生；摘要刷新不能清除 Open 失败。
Open 失败保留稳定目标 ID，旧 Pane/Session 不变；“重试打开”只重试该 ID。
取消及旧导航不写入读取失败；实际打开成功清除 Open 失败。
Recent View 使用已有可取消 historyAction，并向辅助技术发布当前操作的失败提示。
播报 API 依据 [Apple UIAccessibility](https://developer.apple.com/documentation/uikit/uiaccessibility)
及 [announcement](https://developer.apple.com/documentation/uikit/uiaccessibility/notification/announcement)。

审查修复首个 tests-only `4834dbf` / CI `36537184942` 的测试编译失败：bridge 为值类型，
不能使用身份比较。该运行不是行为 RED；改用真实 Session 身份，生产代码尚未修改。
有效 tests-only `e66dde506c84e4f809603788d6b296b80e19a366`，tree
`0ac5b3db76c2a31e4cf01d6d4714d92b0d4103da`；push CI `36542576776` attempt 1 /
job `109321286051` 生成、应用和测试编译通过；746 Swift Testing / 111 suites 实际运行，
只有两个新增行为断言失败：未知 Run 元数据、Full-only SQL 故障均没有可见 Recent 错误。
20 XCTest 通过；14 UI 中原有中文输入断言观察到“你”而非“你好”。一次实际测试启动，无宿主重启。
之前相同源码 `34c88ec` 的 push 完整通过，重复 PR CI `36534277964` 初次输入键盘焦点失败。
两条设备/模拟器输入观察保留，原因未确定；不得声称已修复输入或以删除断言关闭它们。
此次最小修复只更改失败事实、提示与重试，最终完整 CI 仍待验证。

## 验收记录

实际 RED/GREEN run、attempt、head/tree、测试数量与独立整分支审查维护在 PR #21；
未取得真实完整 CI 之前不宣称 H2 完成。
真机 Gate A、中文/emoji 输入选择、触摸/无障碍、Instruments/主线程耗时、内存和舒适度继续待验收。
未新增 IPA、签名流程或 S5-05/后续功能。

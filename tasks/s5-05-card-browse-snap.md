# S5-05 — Card Browse / Snap

## 范围与授权

依据用户粘贴的 S5-05 方案及 Blueprint `596a84d` 的开发规划、CONTEXT、App Space / Split / 全局导航笔记执行。
用户于 2026-09-29 调整顺序：合并已验收 H2 → 开发 S5-05；真机 Gate A 保持待验收。
这项调整允许开发，不关闭设备、输入、无障碍、性能或舒适度验收。

基线：H2 squash `eec3eb38c3d4869a58031449f303f04dec55d0fd`，
tree `2d8f16749fb0cdfcf328982d73250d073e612777`。
主线 CI [36555411803](https://github.com/54zhien/Zen-Agent/actions/runs/36555411803)
生成、构建通过；746 Swift Testing / 111 suites、20 XCTest、14 UI 通过，宿主终止检查通过。
一次实际 Swift 测试启动，无实际宿主重启。

分支 `codex/s5-card-browse-snap`，独立 [PR #22](https://github.com/54zhien/Zen-Agent/pull/22)。
复用已有受管理工作树；桌面主 checkout 保持干净 main。PR #22 尚未合并。

## 行为与所有权

- 在既有右偏深度卡片栈水平浏览；松手根据位移与速度最多切换一个邻居。
- 只保留 Current + 最多 3 条较旧摘要 + 1 条最近较新摘要；一次数据库读取快照内完成有界 keyset 查询。
- Workspace 保存摘要窗口、选中项和纯运动状态；浏览不读取 Full timeline、不创建 Pane/Session、不改变 userActiveAt。
- native Surface 保留同一个 hosting child；Card 专用水平 UIPan、原生动画和前后会话无障碍动作共享同一步进状态。
- 拖动和结算期间冻结窗口；取消、尺寸/场景变化、Return 中断会使旧结算失效，恢复最后提交的选中项和实际 Surface 几何。
- 激活选中卡片才交给已有 HistoryPreparation / Preview Return owner；准备完成前保留原 Session。
- 接受跨会话交接后延续既有两段 Return 动画；保留原草稿、阅读锚点和隐藏 Run，不发送 Stop。
- 刷新或 Full 读取失败保留可读卡片和原 owner，并显示可重试错误。
- 已存在的未落库原始会话可返回同一个暖 owner；New sentinel 不创建新会话。

没有新增数据库/schema、依赖、签名、IPA；没有实现 New 创建、Pin、Rename、Delete/Undo、Split 或后续导航/Settings 切片。
数值阈值是本实现的归一化校准参数，不是 Apple 保证，也不代表真机手感验收。

## 可运行 RED

编译失败、缺失符号、被替代或取消的运行不算行为 RED。新纯状态/窗口 API 先以惰性兼容接口使测试可编译，
保持原 Return 默认行为；实际失败确认后才写对应功能代码。Task 2/3 按摘要/状态 → 原生输送 → 显式 Full 交接顺序实现，
作为同一垂直切片提交完整生产候选，不以静态检查宣称 GREEN。

| 范围 | 源码 / tree | 实际 PR CI | 结果 |
|---|---|---|---|
| 既有原生手势 API | `f5bb525438497015c02ee97e2c801f33283695f8` / `b9267e3715729ffdd13a1901f5254d79db2023c0` | [36556936949](https://github.com/54zhien/Zen-Agent/actions/runs/36556936949), job `109368288992` | 生成、App/测试编译通过；746 Swift / 111 suites、20 XCTest 通过；15 UI 恰有 1 个新增浏览失败，原 14 UI 通过 |
| 纯状态、窗口、选中交接 | `c68494d36d9a9357b37248cba0367df54204bcbc` / `72f8b15384051a4b4579452ee00240d44c58c424` | [36558853700](https://github.com/54zhien/Zen-Agent/actions/runs/36558853700), job `109374751998` | 生成、App/测试编译通过；755 Swift / 112 suites 的 56 个新增行为问题；20 XCTest 通过；15 UI 仅原新增浏览失败 |
| 实际无障碍动作、弱 Session、多窗口 UI | `880d8d2f4435205377312affc9647a1623d41f86` / `85fdee1ac3f490b12110e0166c0c2c135e64cb49` | [36560667486](https://github.com/54zhien/Zen-Agent/actions/runs/36560667486), job `109380534964` | 生成、App/测试编译通过；757 Swift / 112 suites 的 72 个行为问题，包含缺少原生 Previous 动作和可淘汰 Session 未释放；20 XCTest 通过；16 UI 恰有 2 个新增浏览失败，原 14 UI 通过 |

三个运行的实际 PR merge tree 分别与对应源码 tree 相等。原首个 UI 测试断言保持不变。
额外的真实 Run 持续流与实际 paused animator 中断测试属于回归控制，不单独声称 RED。

## 完整候选与审查

生产候选 `1d15b8ebb1031402c5613ce0784784d795694962`，tree `5fc900d1509065c57ca511fe77e90289ffb64dbb`。
本地 staged tree 与 API 发布 tree 相等；静态 whitespace/path/hygiene 检查未发现错误。
完整 CI [36563796166](https://github.com/54zhien/Zen-Agent/actions/runs/36563796166), job `109390776055`，
及 push CI `36563790733`, job `109390752930` 均在 30 分钟上限终止：生成、App/测试编译通过，
既有 `nativePreviewEditorReleaseAndSelection` 测试开始后停住，未取得完整 Swift/XCTest/UI 结果。
终止前各有一次实际 Swift 启动；尚未执行宿主检查，不声称该检查通过，也不将超时称为键盘偶发问题。

停止前的新控制有三条断言问题：完成 Run 后正常流终止计数是 1；实际 native Return 在 800ms 后仍为 Card、没有 Pane。
`Stage2StreamBox` 的 onTermination 也统计正常结束，已将完成后的精确计数改为 1；
保持 Run 活跃时及跨会话接受后计数为 0，并验证最终 completed 与实际 late delta。不是取消生产行为或删除断言。

诊断源码 `45a30b588d6cd964773448b3d8209b6b758f37a1`，tree `f31c4e0a31b6b4c466c263419ebd64533e99f0d9`，
增加有限的 native Return、编辑器挂载/进入 Preview/释放/回交与 viewport/body 阶段日志，无产品修复。
诊断 CI `36567500173` 待定位；文档发布可能替代它，替代运行只提供诊断，不能算行为 RED/GREEN。
完整候选验证与一次独立全分支审查仍待确认。此处不宣称 S5-05 已验收。

## 保留的设备门与历史观察

真机 Gate A、Memory Graph、SwiftUI body 次数、动画卡顿、峰值内存、舒适度、VoiceOver 操作和中文/emoji 选择仍缺设备证据。
H2 的历史 CI `36534277964` 初次键盘焦点失败、`36542576776` 中文输入观察到“你”而非“你好”保留；原因未确定。
后续绿色 CI 不代表这些输入问题已修复，未删除或放宽原断言。

本切片收口后停在 PR 交付；S5-06～16 仍为后续工作。

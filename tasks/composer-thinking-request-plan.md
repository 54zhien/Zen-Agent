# 思考选择与真实请求 Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement task by task.

**Goal:** 启用按模型能力展示的思考选择，选择真实进入后续 Run 的请求。

**Architecture:** Provider 声明有序档位集合和默认值，Conversation 保存选择。Send 再校验并冻结 typed effort，适配器只从 frozen seed 编码；不读取活动 UI。

**Tech Stack:** Swift / SwiftUI / UIKit / GRDB / XcodeGen / macOS CI.

**Spec:** Blueprint `Design/Zen Agent Conversation UI 与 Composer.md` 2026-10-20 追加确认。

## Constraints and review focus

- 保留既有 Run 冻结、幂等提交、凭据边界；未知能力不推断。
- 三档、四档、六档、无控制能力均须覆盖；模型切换清除不兼容选择。
- 新 seed 格式读取旧无 effort Run；旧程序拒绝新格式；继续区分损坏与未知版本。
- 不更改 Provider 文本提示来模拟强度，不把推理内容输出能力等同于可调节能力。
- 键盘替代菜单、原浮动菜单都要支持选择，活动 Run 不受后续选择污染。

## Tasks

- [x] 先写真实 HTTP body 与入口交互回归，提交并启动 RED CI；保留 run 记录。
- [ ] `App/Provider/ThinkingEffort.swift` 定义六档词汇与 capability；`ModelDescriptor` 声明能力，DeepSeek 只声明 low/high/max。
- [ ] `ConversationComposerConfiguration` → `ComposerSendCoordinator` → `SendCommand` → Runtime 再校验 → `RequestConfigSeed` v2；默认无显式选择维持旧请求行为。幂等摘要包含已选 effort。
- [ ] DeepSeek 完整与流式请求都从 frozen seed 编码 `reasoning_effort` 和启用 thinking；拒绝不支持值，旧 seed 无参数。
- [ ] 两套菜单复用二级档位面板，返回、关闭、读屏、选择状态；各会话隔离。
- [ ] 补齐持久化、冻结、幂等冲突、三档/四档/无能力和模型切换单元测试；运行真实 CI。
- [ ] 导出六档明暗预览并审查键盘替代面板；按实际结果记录，不声明实机验收。

## Execution ledger

- UI RED: source `a6ff92e`, run [39412629426](https://github.com/54zhien/Zen-Agent/actions/runs/39412629426), real build succeeded; `testThinkingEntryOpensAndKeepsSelectedLevel` failed because Thinking was disabled. The parameterized unit-only filter selected 0 tests; this is not wire RED or GREEN. Final profile selects the entire unit target so the body tests actually execute.
- Ruling: reuse the observed feature-entry RED for this vertical slice; never count the zero-test result as evidence. Wire, persistence and capability behavior require the full unit result before completion.
- The initial canceled dispatches `39412165684` / `39412221720` are setup/concurrency records, not behavior evidence. The first was stuck uploading after cancellation; force-cancel retained its run and unblocked the corrected distinct ref.
- Implemented model-declared sets, model-switch normalization, SendCommand propagation and pre-commit validation; v2 frozen effort and default-compatible digest; complete/stream wire encoding; history/session restoration and target-identity checks. These remain candidates until CI.
- No provider API key or live billable inference is used in tests. FakeHTTPTransport inspects the actual adapter request, separate from physical-device UX acceptance.

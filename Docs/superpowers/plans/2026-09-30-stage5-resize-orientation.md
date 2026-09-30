# Stage 5 Resize and Orientation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete S5-10 and S5-11 after the S5-09 code gate, retaining each Pane's reading, draft and Run ownership during resize, closure and rotation.

**Architecture:** Extend the existing Split arrangement with ratios and axis, and let Workspace consume one geometry projection. Reuse `ConversationPaneScrollBridge` for bottom-edge restoration and the stable physical Surface hosts established by S5-09. Device orientation changes presentation, never Runtime ownership.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI/UIKit, iOS 26, XcodeGen, existing Swift Testing/XCTest/UI suites.

**Spec:** Blueprint `Design/Zen Agent 开发规划.md` Stage 5 steps 10–11; `Design/Zen Agent App Space、Split 与全局导航.md` §§8–12, 18; `Design/CONTEXT.md`. User decisions are in Blueprint PR #5.

## Global Constraints

- “拖 Divider 时两个 Pane 的 Timeline 都保持**底部逻辑锚点**”。
- “不在 resize 中主动 scrollToBottom”。
- “关闭 Pane”只是退出 Split workspace arrangement：不删除 Conversation，也不自动 Stop active Run。
- iPhone 横屏显示 lastActivePane，旋回竖屏恢复 Split。
- 横屏期间的新消息、新 Run、模型选择归属于可见 Pane；另一 Pane 不变。
- iPad 不自动根据旋转替用户切轴；top maps to left and bottom maps to right when the user changes axis.
- App Space keeps its card stack in iPhone landscape.
- All work remains on stacked, unmerged branches. Full macOS generation/build/tests precede the next slice. Physical-device gates remain open.

## Review Focus

1. Resize while reading old content and while both Runs stream: neither Pane jumps to latest or contaminates the other's anchor.
2. Dynamic Type / narrow viewport: minimum dimensions remain usable; invalid geometry cannot commit a ratio or close a Pane.
3. Closing the original source: the secondary native Surface survives and expands continuously, including an active Run.
4. Rotation during Card preparation/Return: cancellation or rebase preserves one owner and the selected card.
5. Landscape edits and model selection: restoring portrait shows those edits only in the previously visible Pane.

## Task 1: S5-10 Divider resize and close

**Files:**
- Modify `App/Workspace/SplitWorkspaceState.swift`, `App/Workspace/WorkspaceSurfaceView.swift`, `App/AppShell/AppShellModel.swift`.
- Create `App/Workspace/SplitWorkspaceGeometry.swift` and `App/Workspace/SplitDividerView.swift` when their real implementations are added.
- Inspect and change only if regressions require it: `App/Conversation/ConversationTimelineView.swift`, `App/Conversation/ConversationPaneScrollBridge.swift`.
- Tests: `Tests/ZenAgentTests/SplitWorkspaceStateTests.swift`, `Tests/ZenAgentTests/ConversationPaneScrollBridgeTests.swift`, `Tests/ZenAgentUITests/SplitContainerUITests.swift`.

**Interfaces:**
- Consume `SplitWorkspaceState.sourceSlot`, `secondaryConversationID`, `activeSlot`; `ConversationPaneScrollBridge.beginHeightChange`, `continueHeightChange`, `endHeightChange`.
- Produce `SplitWorkspaceState.topBottomRatio: Double` initially `0.5` and `setRatio(_ ratio: Double)`; reject non-finite values before mutation.
- Produce `AppShellModel.closeSplit(keeping slot: SplitDropSlot)`; existing `closeSplit()` retains its source-preserving behavior.
- Geometry produces both Pane frames and a Divider frame from size, safe area and ratio. Pane and Divider frames share the same safe viewport.

- [ ] Add a production-root UI regression: open an occupied Split, drag the Divider Handle, assert both editor frames change in opposite directions while IDs and drafts remain. The initial static Divider must fail this behavior test after compiling.
- [ ] Add resize regressions for both reading and following-latest modes, independently seeded Pane anchors, and two streaming Runs. Assert the bottom reference Turn retains its logical distance from the viewport bottom through repeated height changes; do not merely test the ratio formula.
- [ ] Publish the test-only tree; record compiled behavioral RED from full macOS CI.
- [ ] Implement Handle-only drag admission, continuous ratio projection, weak snaps at `1/3`, `1/2`, `2/3`, and distinct rubber-band / close-intent phases. Treat minimum sizes and distance bands as device-calibration values derived from available geometry, Dynamic Type and Composer clearance, not fixed product invariants.
- [ ] Implement explicit release-to-close of the smaller Pane and native expansion of the survivor. Cancellation restores the pre-drag arrangement. Runtime registrations and warm Session state outlive a closed Pane.
- [ ] Add accessibility adjustable actions and explicit close-top/close-bottom actions; expose the ratio and Pane identity in accessible copy. Tapping a broad Divider line must not accidentally close a Pane.
- [ ] Verify both close directions, cancellation, non-finite/too-small viewport inputs, and retained Runs; run `git diff --check`, commit explicit files, publish, and pass XcodeGen/build/unit/UI CI.
- [ ] Review the complete S5-10 diff and record exact SHA/tree, CI and deferred device calibration before S5-11 production work.

## Task 2: S5-11 device presentation and iPad axis

**Files:**
- Modify the Task 1 arrangement/geometry/Divider files and `App/Workspace/WorkspaceSurfaceView.swift`.
- Modify `App/Workspace/AppSpaceGeometry.swift` / Browse geometry only where landscape constraints require it.
- Create `App/Workspace/WorkspaceDevicePresentation.swift` for device/viewport presentation policy; it contains no Session or Run ownership.
- Tests: `Tests/ZenAgentTests/WorkspaceDevicePresentationTests.swift`, existing App Space geometry tests, `Tests/ZenAgentUITests/SplitContainerUITests.swift`.

**Interfaces:**
- Produce `SplitWorkspaceAxis` with `.topBottom` / `.leftRight`, `SplitWorkspaceState.axis`, and separate `topBottomRatio` / `leftRightRatio` values. The active ratio is selected by axis.
- Produce `WorkspaceDevicePresentation` values `.single`, `.split`, `.landscapeSingle(SplitDropSlot)` from device idiom, viewport and saved arrangement.
- Consume the S5-09 user-focus-owned `activeSlot`; neither streaming events nor rotation updates it.

- [ ] Add a production iPhone UI test: focus one Pane, dismiss its keyboard, rotate landscape, assert one visible editor belonging to that Pane; edit its draft, rotate portrait, assert two original IDs, saved ratio and only that Pane's updated draft.
- [ ] Add Card rotation UI coverage: current selection survives portrait→landscape→portrait and Return still targets its original logical Pane/Conversation.
- [ ] Publish compiled behavioral RED before changing the device presentation policy.
- [ ] Implement landscapeSingle by changing frame/visibility while retaining both Pane owners. Route visible New/Recent/model/Send actions through that Pane's existing bridge. Rotation back restores axis/ratio and each Session's own reading state.
- [ ] Implement iPad axis selection from long press on the Divider Handle with a native direction menu. Map logical top→left and bottom→right, restore the selected axis's saved ratio, and animate the existing hosts continuously.
- [ ] Adapt App Space minimum card dimensions and distances to actual landscape safe height. Keep bounded predecessor projection, selected identity and New's rightmost ordering.
- [ ] Verify iPad policy and native host geometry for both axes, iPhone UI rotation, rotated cancellation, and independent Run/model state. Pass full macOS CI and review before Sidebar implementation.

## Pending product decision

IME marked-text navigation/focus policy is explicitly unresolved in the Blueprint; the question is already with the owner. Apply that answer consistently when it arrives. It is not permission to force-commit or cancel composition. Ordinary non-composing focus and independent geometry work can proceed.

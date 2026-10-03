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
- All work remains on stacked, unmerged branches. Full macOS generation/build/tests precede production work in the next slice. Physical-device gates remain open.

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
- Native Lift/Return destinations consume that same measured viewport. Do not assume a window's safe insets and a nested `GeometryProxy` report identical values; the integration check compares the actual mounted Pane frame with the transition destination.

**Resize transaction ownership (source review):**
- Workspace owns the gesture transaction, original arrangement/ratio and stable window-coordinate displacement. Each Timeline owns its actual latest ScrollGeometry and measured bottom reference Turn; begin intent reaches each bridge/Timeline independently, never a shared synthetic anchor.
- A Divider token/lease owns its captures through release/cancel, including programmatic scroll idle and prior deceleration. Keyboard/Composer changes retain their separate capture semantics. Native UIPan cancellation, scene interruption and replacement/close paths all release the same lease.
- Bind the transaction to both Conversation IDs and the original Split arrangement. Cancellation restores the original ratio only while that arrangement still exists; a late callback cannot write it into a replacement Split. Keep captures until rollback geometry has been consumed, then release them.
- Hold safe Pane lifetime during any deferred geometry completion: bridges hold `unowned` Pane references. Close, model replacement, context-menu and accessibility actions must invalidate the old transaction before retiring its owner, or retain that owner until guarded callbacks finish.
- Changing viewport bounds also invalidates Lift geometry. That does not end the separate Divider transaction. Admit Divider input only with both hosts Full, and share the saved ratio with all Split Return destination calculations.
- The Handle owns a native pan recognizer and explicit native close menu/actions; the broad Divider line does not claim taps/drags. Continuous close promotes the survivor's existing physical host and Pane/Session, rather than remounting its Composer in the other host.
- A stable physical host alone is insufficient for close-source: `WorkspaceHostedContent` currently switches a secondary live `SplitSecondaryPaneView` into the generic source `NewConversationView` on promotion, which can replace its native editor/scroll subtree. Give both physical slots the same live-content structure with role-dependent actions before relying on continuous closure. Keep launch/no-Pane content separate. Verify the actual native editor identity across close, in addition to retained Pane/Composer objects and draft text.

- Completion protocol (read-only source review): Timeline publishes usable geometry, its measured bottom reference, Turn-frame generation and layout revision to its own bridge. Divider captures both participants synchronously before ratio mutation. Finishing/cancellation carries a final layout revision through both the ScrollGeometry transform and Turn-frame preference payloads, including an explicit empty-timeline measurement. A Pane receipt includes lease ID, arrangement ID, Pane ID, final revision and applied scroll sequence; emit it only after current-revision geometry/frames exist and the final bottom-edge request reaches its target and clears via `markScrollApplied`. Release participants independently on those receipts, then finish the Workspace transaction after all required acks. Streaming after an ack is post-capture work, so a live Run cannot starve completion. The disappearing Pane's lease is invalidated before retirement; the survivor remains captured through expansion. Ordinary idle/keyboard captures never release the outer Divider token.

- Divider implementation preflight: attach native pan and context-menu interactions only to the narrow Handle view; the broad line remains non-interactive. Measure pan translation in the window, since the Handle itself moves as ratio updates. Gesture begin captures the arrangement identity, original ratio and retained Pane owners; every update/finish checks the same arrangement before mutation. Accessibility adjustment clamps to usable Pane sizes and never enters drag-to-close; explicit close actions retain their distinct semantics. Scene cancellation restores the captured ratio before releasing reading captures after the final measured geometry.

- Shared live-content design: parameterize the existing `NewConversationView` by physical Surface slot, resolve its current source/secondary Pane and bridge internally, and keep one NavigationStack with `.id(pane.conversationID)` at the same subtree level. AppShellRoot supplies the same view type to both stable hosts. Preserve the generic no-model Workspace/test-harness initializer; generic fixture content must not silently become the product screen. Role-dependent New/Recent/title/configuration actions stay inside the shared view, and the identity-change observer follows that slot's actual Conversation ID, so source promotion with unchanged ID does not reset Lift or remount content.

- Native continuity evidence: extend the existing DEBUG native interaction probe with the actual editor `ObjectIdentifier`; close UI regressions compare that value on the survivor's original physical host before/after closure. Add the probe field as test scaffolding when publishing S5-10 RED, not as a replacement for the actual frame/draft assertions. Later model ownership tests additionally assert the survivor Pane/bridge/session identity and both active Run registrations.

- [ ] Add a production-root UI regression: open an occupied Split, drag the Divider Handle, assert one mounted Pane grows while the other shrinks and IDs/drafts remain. Measure Pane frames: the bottom Pane's editor can correctly stay at the same screen bottom. The initial static Divider must fail this behavior test after compiling.
- [ ] Add resize regressions for both reading and following-latest modes, independently seeded Pane anchors, and two streaming Runs. Assert the bottom reference Turn retains its logical distance from the viewport bottom through repeated height changes; do not merely test the ratio formula.
- [ ] Check the real Timeline integration across programmatic scroll idle callbacks and token-driven content height changes. The current bridge captures a bottom anchor, but Timeline ends its height-change capture on scroll idle; a Divider gesture must retain one resize transaction until release/cancel, with keyboard/Composer changes retaining their separate semantics.
- [ ] Exercise starting Divider resize while a Pane's prior scroll is still decelerating. Timeline currently checks `isUserDrivenScroll` before viewport changes, so resize geometry can reach `userScrolled` and clear the captured bottom anchor. Explicit Divider ownership must take precedence for its duration. Token-driven content-height changes must reapply that same capture even when no further Turn-frame preference arrives.
- [ ] Cover different top/bottom reference Turns: `paneHeightChanged` currently derives an offset from the bottom reference but keeps the previous top anchor's Run ID. Verify that a subsequent token update restores the same position, then correct the identity/offset pair after compiled RED.
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
- [ ] In landscape App Space, also select the already occupied opposite Conversation and Return. The visible live content must belong to that selected existing owner; restoring portrait retains both original logical slots and their states. Inspect the native late-handoff mapping so it cannot briefly install the initiating Conversation under the opposite card.
- Return preflight review: keep the physical Card origin distinct from the selected existing logical Pane and its stable physical live host. The present Return animator stays bound to its Lift-origin host, so changing only its destination rectangle can briefly install the initiating Pane under the opposite selected Card after commit. Prepare an explicit Return presentation plan before handoff; reveal the selected owner and keep the initiating host Preview-only until its exit completes. Add deterministic plan/phase-owner coverage, because the final-state UI assertion alone cannot observe this intermediate mismatch. Preserve original Pane-to-host mappings.

- Cross-owner Return implementation boundary: prepare a Workspace-owned presentation plan from initiating physical slot, selected existing logical owner, device presentation and destination. Keep the origin's actual Preview host at its App Space viewport through the final native animation when the selected owner is the other physical host. At commit, mount only that other owner's existing live host behind the matching preview destination; retain the selected Preview descriptor in the Workspace presentation state until convergence. Do not rebase/install the initiating editor under the selected Card. On convergence hide the proxy host before clearing its held Preview, then restore its own logical slot (or keep it hidden in landscape). Cancellation clears only the presentation hold; a committed logical selection remains with its selected owner. No snapshot replacement or duplicate editor is required. Generic/no-model host fixtures keep the normal Return path. Cover prepared/handoff/completion plan ownership and paused native final-segment behavior, not only final UI state.

- Cross-owner completion protocol: completion must not depend on the origin shrinking. The origin remains a full App Space proxy, so its old pendingViewportReturn callback cannot prove that the destination live host is mounted. Keep drawing visibility separate from input/accessibility visibility: mount the selected live host behind the proxy, suppress its editor and accessibility until convergence, and retain an immutable selected Preview descriptor before commit clears Browse. Resume only after the target host supplies its actual window frame in a native layout receipt and the target Timeline supplies current revision/visibility geometry plus applied-scroll completion. Use the measured native target frame for the final destination rather than assuming Window safe insets equal the nested GeometryProxy. Tokenize preparation, target receipts and cancellation; hide the native proxy before clearing its descriptor. Animation interruption after logical commit retains the selected owner. The final UI tests cannot prove that no wrong owner was briefly shown; add a paused native final-segment assertion.

- [ ] Publish compiled behavioral RED before changing the device presentation policy.
- [ ] Implement landscapeSingle by changing frame/visibility while retaining both Pane owners. Route visible New/Recent/model/Send actions through that Pane's existing bridge. Rotation back restores axis/ratio and each Session's own reading state.
- [ ] Implement iPad axis selection from long press on the Divider Handle with a native direction menu. Map logical top→left and bottom→right, restore the selected axis's saved ratio, and animate the existing hosts continuously.
- [ ] Adapt App Space minimum card dimensions and distances to actual landscape safe height. Keep bounded predecessor projection, selected identity and New's rightmost ordering.
- [ ] Verify iPad policy and native host geometry for both axes, iPhone UI rotation, rotated cancellation, and independent Run/model state. Pass full macOS CI and review before Sidebar implementation.

## Pending product decision

IME marked-text navigation/focus policy is explicitly unresolved in the Blueprint; the question is already with the owner. Apply that answer consistently when it arrives. It is not permission to force-commit or cancel composition. Ordinary non-composing focus and independent geometry work can proceed.

## Execution ruling — 2026-10-04

Ruling: permit test-only S5-10 CI to run alongside the final S5-09 test-query
repair CI. S5-09 source already passed build, 837 Swift and 20 XCTest twice;
29 existing UI tests passed and the only failure was an ambiguous newly added
query. No S5-10 product implementation begins until S5-09 is green. The S5-10
test tree includes the same repaired S5-09 regression and adds only tests,
DEBUG identity instrumentation and this ledger. Cost if wrong: any further
S5-09 repair is applied to the S5-10 baseline before production work, and CI
receipts are kept tied to their own exact trees. This reduces duplicated
waiting without weakening either acceptance gate.

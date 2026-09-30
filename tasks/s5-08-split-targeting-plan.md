# S5-08 Split Targeting Implementation Plan

> **For agentic workers:** Use `superpowers:executing-plans` task by task. S5-07 must have exact-tree GREEN before production changes begin. The owner has already authorized continuing Stage 5 through implementation; its whole-stage review and device testing follow development.

**Goal:** During an eligible Composer Lift, show top/bottom Split targets, move the actual Surface toward the selected Pane while the finger moves, and emit an exact target on release for S5-09's Split Container.

**Architecture:** Keep `SurfaceLiftController` as the transition owner and `ComposerLiftInteraction` as native input transport. A small geometry/state unit owns target hit regions and the preview pose; the host still transforms its existing child rather than constructing another Timeline. The drop result is a captured Conversation ID plus top/bottom slot; S5-09 will consume it to create the second Pane.

**Tech Stack:** SwiftUI, UIKit, Swift Testing, XCTest UI, existing `SurfaceGeometry`/XcodeGen/macOS CI.

**Spec:** Blueprint `Design/Zen Agent 开发规划.md` Stage 5 Split Targeting step, `Design/Zen Agent App Space、Split 与全局导航.md` §§2, 8, 17–18, `Design/CONTEXT.md`; current S5-07 branch after its final CI. Read the current Blueprint head and repository again before implementation.

## Global Constraints

- Keyboard hidden, stable Composer, no editing/selection/overlay remain Lift prerequisites. A failed prerequisite cancels targeting without a drop.
- Both Drop Zones are weak and textless; only the current finger target strengthens. The live Surface is the preview. A target entry receives one light haptic, not one per frame.
- Release continues from the current pose with only a short final convergence; cancellation/backtracking returns the same Surface without replacing the editor or stopping a Run.
- Target slot and captured Conversation identity must survive an asynchronous release handoff. Late gesture/animation callbacks cannot retarget another Conversation.
- S5-08 exposes a real drop intent; S5-09 owns the actual Split Container and Divider. Until a consumer is installed, release must safely return to the existing App Space/Full route. No production placeholder Pane or duplicate Composer is allowed.
- Preserve the current `project.yml`/xcconfig structure; no new dependency or generated project edits. Publish behavioral RED, then full macOS generation/build/test GREEN on a stacked branch.

## Review Focus

1. Tiny/invalid safe viewport or large Dynamic Type: no invalid pose or invisible target. Task 1 tests it.
2. Finger oscillates across the middle boundary: target/haptic changes only on actual zone entry and never floods. Task 1 and 2 tests it.
3. Gesture cancellation, app inactive, or eligibility change: original Surface and draft remain intact. Task 2 tests it.
4. Selected Conversation changes before drop completion: no other ID enters Split. Task 2 tests it.
5. Accessibility users cannot perform the drag: provide a target action path once the S5-09 consumer exists, and keep the action unavailable until then. Task 2 tests the exposed action state.

---

### Task 1: Existing Lift behavior RED, then target state and geometry

**Files:** Extend `Tests/ZenAgentUITests/SurfaceLiftUITests.swift`; create `App/Workspace/SplitTargeting.swift`; create `Tests/ZenAgentTests/SplitTargetingTests.swift`.

**Interfaces:** `SplitDropSlot` is `.top` or `.bottom`. `SplitTargetingState.update(point: CGPoint, viewport: CGRect, liftProgress: Double) -> Update` returns `Update(slot: SplitDropSlot?, enteredTarget: Bool)`; `end(cancelled: Bool) -> SplitDropSlot?` returns the captured target. `SplitTargetingGeometry.preview(slot: SplitDropSlot, progress: CGFloat, size: CGSize, safeArea: UIEdgeInsets) -> Preview?` returns `Preview(pose: SurfaceGeometry.Pose, paneFrame: CGRect, guideFrame: CGRect)`. The exact hit regions are calibrated from the safe viewport and documented as tunable values, not product constants.

- [ ] First add `testComposerDragTargetsTopSplit` and its bottom counterpart to the existing native Lift UI fixture. Use the existing Composer selector and drag gesture; after release, assert a DEBUG-only `split-drop-top-intent` / `split-drop-bottom-intent` probe records the captured target. The selector strings compile before production support exists, so this is a behavioral RED. Publish that test-only run and record the actual assertions and existing Lift controls. Task 2 separately checks live preview pixels while the gesture is active.
- [ ] Add the new state/geometry signatures and focused tests for top/bottom selection, neutral middle, target change, cancellation, invalid viewport, safe-area containment and a preview that has already traversed roughly 80–90% of the distance to its 50/50 Pane frame before release. This range is a starting visual calibration, not a permanent layout constant. Missing symbols or compilation failure are not RED evidence; the preceding native test is the behavioral proof.
- [ ] Implement the smallest pure state/geometry unit. Do not add a Split view or an empty manager.
- [ ] Run full macOS CI; keep the exact tree, test counts and failures in the slice record.

### Task 2: Live Surface transport and native input

**Files:** Modify `App/Conversation/ConversationComposerView.swift`, `App/Conversation/ComposerLiftInteraction.swift`, `App/Workspace/SurfaceLiftController.swift`, `App/Workspace/WorkspaceSurfaceView.swift`, and the existing Surface host only where needed; extend focused unit and UI tests.

**Interfaces:** `ConversationComposerView` passes its existing `conversationID` into `ComposerLiftInteraction.Configuration`; the native transport forwards the finger's window location and cancellation to `SurfaceLiftController`. The controller captures that ID when arming, applies the Task 1 preview pose to the existing Surface, and sends `SplitDropIntent(conversationID: String, slot: SplitDropSlot)` to `configureSplit(onDrop: @MainActor (SplitDropIntent) -> Bool)`. S5-09 installs that closure; a missing/rejected consumer returns the Surface through the current safe route.

- [ ] Add behavioral tests for a real drag from the Composer into each target, one haptic per entry, backtracking, cancellation, stale captured ID and missing/rejected drop consumer. Keep native draft/reading-position assertions.
- [ ] Publish compiled behavioral RED before transport changes.
- [ ] Implement native coordinate forwarding and Surface preview without reparenting or duplicating the content controller. Render weak textless zones and the guide only during targeting.
- [ ] Run full macOS CI, including existing Lift, Browse, Delete and Return UI tests. Record exact-tree results; then hand the intent interface to S5-09.

## Boundary to S5-09

This plan does not claim a usable two-Pane workspace. S5-09 consumes `SplitDropIntent`, owns distinct Pane/Session identities, starts at 50/50, and makes the guide a Divider. Do not mark Split complete from Task 1 or Task 2 alone.

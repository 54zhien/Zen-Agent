# Stage 5 device feedback implementation plan

> **For agentic workers:** Use superpowers:executing-plans. The owner approved these corrections after discussing the screenshots and selected the active Pane as the shared Composer's Lift target.

**Goal:** Correct Split input ownership and presentation, remove chat navigation chrome, and make Lift and Browse follow the approved spatial behavior.

**Architecture:** Conversation sessions retain their own Composer, draft, selection and Run. Workspace owns the shared Split input presentation and active-Pane routing. Existing native Surface hosts retain gesture, interruption and Return ownership; geometry changes must not introduce a second runtime or scroll owner.

**Tech Stack:** Swift 6, SwiftUI/UIKit, XcodeGen, iOS 26, macOS GitHub Actions.

**Spec:** Blueprint `Design/Zen Agent App Space、Split 与全局导航.md`, owner feedback of 2026-10-05 and `Design/ADR/0006-split-pane-lift-returns-to-split.md`.

## Global Constraints

- No main merge, Stage 6 work, dependency, persistence schema or provider changes.
- Preserve independent drafts, selection, attachments, configurations, reading positions and active Runs.
- Active Pane is latched when Lift begins. Cancel restores the arrangement; selected Return replaces only the origin, or activates the already occupied target.
- XcodeGen/build/tests must actually run in CI. Device comfort remains a separate acceptance gate.
- Baseline: local d4e098563e76fa614021ae45dbfd56ca0a85dc45, remote 95d07d15bd2be54d6747ca4f16c9420d7c88286f, identical tree b274c43a8daff4c5466d9b2f1199766290607291; checkpoint/s5-before-device-feedback-20261005 preserves it.

## Review Focus

- IME and selection transfer between active Panes must neither discard input nor send another Pane's draft.
- A shared input outside a Pane must still route Lift and Sidebar native readiness to the active host.
- Interrupted Lift/Return and orientation changes preserve the original Pane and the other Run.
- Horizontal card depth changes preserve every card's vertical center, including boundary rubberband and New.
- Sidebar operations in Split affect the active conversation; overlays restore focus only to the same retained owner.

### Task 1: Continuous Lift and horizontal App Space geometry

**Files:** `App/Workspace/{AppSpaceGeometry,AppSpaceBrowseGeometry,SurfaceLiftGeometry,SurfaceLiftController,AppSpaceInkView}.swift`; `Tests/ZenAgentTests/DeviceFeedbackGeometryTests.swift`.
**Interfaces:** Existing `AppSpaceBrowseGeometry.resolve`, `SurfaceLiftController.arm/drag/end` remain. Add a pure interactive Lift pose using upward displacement, separate from destination geometry used by Return.

- [ ] Add behavioral tests: every Browse sample shares one centerY, outgoing card moves left and shrinks, native Lift at 80/140 points has zero horizontal displacement and corresponding vertical translation with no crop, light canvas has a distinct darker background.
- [ ] Publish test-only candidate and observe actual assertion failures in macOS CI (`review-red` runs all unit tests).
- [ ] Implement horizontal centered scale, nonwhite canvas and direct vertical interactive Lift. Keep destination convergence and cancellation continuous from the presented pose.
- [ ] Run all unit tests and relevant Lift/Browse UI tests; record exact remote SHA/tree and result.
- [ ] Commit this slice before input routing changes.

### Task 2: Shared Split input, structural divider and Sidebar controls

**Files:** Workspace composition, native Composer bridge, Conversation Pane presentation, AppShell active-Pane routing, Sidebar/overlay composition, related unit/UI tests. Add focused shared-input and navigation-action boundaries rather than extending unrelated runtime state.
**Interfaces:** Workspace resolves `(Pane, actionBridge, surfaceSlot)` from `SplitWorkspaceState.activeSlot`; the existing per-session send coordinator remains authoritative. Pane content receives a dock placement and bottom-clearance policy. A native Composer portal keeps each mounted Pane's existing editor, parks inactive editors outside the window, and reparents only the active editor into one Workspace dock. Marked text and selection/quote drags block owner transfer; ordinary editing transfers focus without replacing either editor. Tap activation is refused during Lift/resize/overlays.

- [ ] Add regressions against current UI: exactly one bottom input in Split; content taps switch draft owner; no chat toolbar controls; Sidebar remains reachable from Split and New. Add divider gap/handle hit-area assertions.
- [ ] Observe behavioral RED before production changes.
- [ ] Render black gutter and continuous adjoining rounded corners, with resizing limited to the white grabber's bounded touch target.
- [ ] Extract shared Composer presentation, wire content-tap activation and latched active Lift; preserve all existing Return paths.
- [ ] Move New, history, Split and configuration navigation to Sidebar; keep Search/Files/Settings and equivalent accessibility actions.
- [ ] Update affected existing tests to use the new visible entry points, preserving their original behavioral assertions.
- [ ] Run full CI and record evidence.

### Task 3: Review and device candidate

- [ ] Fresh whole-branch review using the requesting-code-review template; adjudicate findings and fix concrete Important/Critical issues with regression evidence.
- [ ] Remove temporary test profiles; require real generation, build, all unit/UI tests and native iPad gate on the final source tree.
- [ ] Package replacement unsigned arm64 IPA from the exact tested source, validate its provenance, fonts, hash and archive integrity.
- [ ] Deliver IPA and concise device checks. Keep all work unmerged and physical acceptance open.

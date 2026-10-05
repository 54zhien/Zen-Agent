# Stage 5 Visual Reinforcement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver S5-16 Ink, restrained parallax and Current Card edge highlight after the navigation and spatial interaction code gates.

**Architecture:** Workspace owns a bounded native background renderer and its motion policy. Browse supplies gesture displacement; Surface supplies the actual visible crop for Current's highlight. Flow, gesture response and Conversation rendering remain independent.

**Tech Stack:** Swift 6, UIKit/Core Animation, SwiftUI settings, existing XcodeGen/macOS CI.

**Spec:** Blueprint `Design/Zen Agent App Space、Split 与全局导航.md` §§3–4, 17–18 and Stage 5 step 16. The Blueprint permits a low-cost prototype before selecting a shader backend from device profiling.

## Constraints and review focus

- Cool black/gray, soft low-contrast ink; no particles, water ripples or Provider branding.
- Independent slow flow and tightly clamped reverse parallax, initially about 2–4 pt.
- Reduce Motion stops flow and parallax but retains static Ink.
- Current alone receives a faint edge highlight, fitted to its visible crop; historical cards express depth through existing geometry and shading.
- Light Ink remains disabled under the conservative approved implementation assumption; an explicit palette decision may follow device review.
- Code/CI completion is separate from GPU, energy, frame pacing and physical comfort acceptance. No costly shader work before those measurements justify it.

## Task: S5-16 bounded native effects

**Files:**
- Create `App/Workspace/AppSpaceInkView.swift` and `App/Workspace/AppSpaceMotionPolicy.swift` with their real implementations.
- Modify `App/Workspace/WorkspaceSurfaceView.swift`, `App/Workspace/AppSpaceBrowseController.swift` only for displacement access, and `App/Workspace/ConversationSurfaceHost.swift` for the native edge path.
- Extend the actual Appearance settings introduced by S5-15 with Ink enablement and a small bounded intensity range.
- Tests: `Tests/ZenAgentTests/AppSpaceMotionPolicyTests.swift`, `Tests/ZenAgentTests/SurfaceLiftHostTests.swift`, Tests/ZenAgentTests/CurrentCardEdgeTests.swift, AppSpaceInkRendererTests.swift, AppearanceInkSettingsTests.swift, and actual SettingsUITests.swift.

**Interfaces:**
- Consume Browse's existing `state.offset`, the Surface visible rectangle/corner radius and system Reduce Motion/low-power/thermal state.
- Produce a presentation policy with flow enabled, parallax enabled and bounded intensity/displacement. It owns no navigation or Runtime state.
- The background renderer uses a fixed small layer count; changing Browse selection never adds layers or starts duplicate animation loops.

- [x] Add native behavior regressions for Reduce Motion retaining a static background, displacement saturation, toggling effects without changing selected identity, and fitting the highlight to an already cropped Surface.
- [x] Publish the tests and observe compiled behavioral RED before adding production effects.
- [x] Implement a low-cost native renderer using soft gradient layers and slow independent transforms. Keep its surface opaque; avoid full-screen live blur and per-frame SwiftUI state updates.
- [x] Implement reverse parallax from Browse displacement with strict finite bounds. Disable it for Reduce Motion, low-power mode and serious/critical thermal pressure. Freeze flow under the same policy and while the scene is inactive.
- [x] Apply a faint Current-only native edge path to the Surface's visible crop. Update on presentation geometry changes, remove in Full, and avoid duplicate outlines on projected history cards.
- [x] Connect persisted Ink settings to the renderer. Keep light-mode Ink off pending a palette decision; preserve the approved card-stack structure in both orientations.
- [x] Verify layer-count stability, repeated background/foreground transitions, reduced-motion changes mid-gesture, selected identity and Return. Run local static checks and full macOS XcodeGen/build/unit/UI CI.
- [x] Review the diff and record exact tree/CI, device profiling checklist and unmerged status in the Stage 5 review handoff.

## Whole-stage handoff

- [x] Reconcile the S5-09–16 implementation records with the approved Blueprint decisions and actual PR heads.
- [x] Confirm all required code gates on the final stacked tree; list any failed or unavailable validation explicitly.
- [x] Give the owner a concise map of the unmerged PRs, exact final head/tree and review entry points. Keep device measurements and comfort/VoiceOver checks open for the owner's next pass.

## Code closeout receipt

Profile-free source db30ed60/tree79f55ccb passed both full runs37247975877/
37247978542 and guard37247978538:942Swift/151suites,20XCTest,54phoneUI
(one expected Pad-only skip,zero failures),actualPad both;oneSwift-run start,
no host restart/retry. Fresh whole-stage review found no concrete Critical,
Important or Minor code defect. See tasks/stage5-code-review.md and the current
handoff for exact reviewed source, historical failures and physical-device limits.
Light-mode Ink remains off; no palette, shader backend or device acceptance is
invented by these checked implementation steps. All stacked PRs remain unmerged.

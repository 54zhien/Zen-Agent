# Sidebar AX composition controls implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task after owner approval. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Identify whether Settings' custom Button style or the Rail reveal mask contributes to its native AX hit failure, without adopting either omission as final UI.

**Architecture:** One DEBUG-only build, three independent launches of the same native Settings route check. Preserve a baseline control and omit exactly one factor in each other launch; remove all variants after collecting evidence.

**Tech Stack:** Existing SwiftUI/UIKit, XCTest, XcodeGen, GitHub Actions macOS/iOS simulator. No dependencies, signing or schema change.

**Spec:** Owner's frozen-UI instruction and narrow interaction authorization; `tasks/ui-integration-test-alignment-20261021.md`; Blueprint `Design/Zen Agent App Space、Split 与全局导航.md` at accepted supplement `6d9b054`.

## Global constraints

- **Owner approved the temporary controls on 2026-10-22:** plain style temporarily omits Settings' 0.92 press scale/spring; mask omission changes reveal clipping and may expose glass overflow.
- Default/release UI remains the accepted `eb39a65` product; neither omission is a delivery decision.
- Keep glass effect/interactive flag, layout, button label/ID, route, eligibility, and haptic closures unchanged.
- No merge or S6 implementation before the original default-source full gate passes.
- No retry loop, coordinate replacement for ordinary navigation, skipped assertion or unchanged retry to replace RED.

## Review focus

- A new conditional wrapper could itself change AX composition: default control must retain the relevant RED, otherwise no causal conclusion.
- Every variant must retain one Settings Button named `设置`, enabled and finitely framed.
- A passing coordinate route does not satisfy a failed AX assertion; retain both.
- The two omissions are independent launches, never combined.
- Diagnostic conditions must not survive into the final product or full merge gate.

## Task 1: Native composition discriminator

**Files and ownership:**

- `App/Workspace/SidebarRailView.swift`: DEBUG selector and Settings-only style omission; other buttons unchanged.
- `App/Workspace/WorkspaceNavigationView.swift`: DEBUG outer-mask omission only; existing opacity, interaction gating and animation order retained.
- `Tests/ZenAgentUITests/SidebarUITests.swift`: common existing route exercise and two separately named variant cases.
- `.github/workflows/ci.yml`: temporarily include the two new cases in `sidebar-hit-path` only; no removed full tests.
- `tasks/ui-integration-test-alignment-20261021.md`: append actual SHA/results/artifact digests and cleanup receipt.

**Interfaces:** DEBUG internal `SidebarAXDiagnosticControl` with `baseline`, `settingsPlain`, `railWithoutMask`, and `static var current: Self`; parse `ZEN_SIDEBAR_AX_CONTROL`, with absent/unknown values using baseline. UITest `launch(withKeyboardMenu: Bool = false, sidebarAXControl: String? = nil)` sets only that test process's environment. No persistent state or production service API.

- [x] Confirm owner approval and clean tracked worktree; preserve unrelated `deep-reading-native-trace.txt`. Re-read pinned navigation note and current source before coding.
- [x] Keep `testSidebarSettingsCoordinateRoutePreservesAXFailure` as baseline. Extract its unchanged body into a private exercise helper; add `testSidebarSettingsWithPlainStyleControl` and `testSidebarSettingsWithoutRailMaskControl`, each launching independently.
- [x] Retain these assertions in every case (including the original native-settlement check):

```swift
XCTAssertTrue(settingsExists)
XCTAssertEqual(app.buttons.matching(identifier: "sidebar-settings").count, 1)
XCTAssertEqual(settings.label, "设置")
XCTAssertTrue(settingsHittable)
XCTAssertTrue(frameIsUsable)
XCTAssertTrue(destinationAppeared)
```

- [x] Add the DEBUG selector. `settingsPlain` replaces only Settings destination's custom ButtonStyle with `.plain`; it retains native interactive glass and the original action/haptic. Available Settings already has opacity 1; its custom pressed scale/spring is temporarily absent.
- [x] `railWithoutMask` omits only the complete outer `.mask` modifier containing `SidebarRailRevealShape.fill(eoFill: true).clipped()`. Keep style, glass, frame, opacity, settlement gating and all other transitions. Never combine with `settingsPlain`.
- [x] Make the profile select baseline plus both cases. Parse Swift sources, validate workflow YAML/Bash and run existing CI-profile checks; inspect diff against the allowlist before commit/push.
- [x] Commit with `[skip ci]`, then dispatch `gh workflow run ci.yml --ref codex/composer-keyboard-sheet-20261020 -f test_scope=sidebar-hit-path`. Real XcodeGen/build is required. Record every case, failure, screenshot/AX hierarchy and actual route; the workflow can remain RED because the baseline failure is intentionally retained.
- [x] If baseline changes, classify controls as confounded; do not call a variant a repair. If a sole omission passes, attribute only to that composition boundary, not automatically to an individual style modifier or a framework defect.
- [x] Remove selector, variant branches/tests and temporary profile selections, restoring accepted UI before any final fix. Preserve all RED/control provenance. Review a minimal nonvisual repair separately; if preserving the accepted animation/clipping is impossible, stop with its concrete impact instead of adopting the omission.

**Failure/cancellation:** Each launch uses the existing isolated preview fixture; no Run, network request, permission grant or user data mutation is added. A failed/cancelled/incomplete native run is not GREEN. Preserve its evidence, then restore the temporary UI variant before any integration. Successful variant evidence is a discriminator, not the final default-source gate.

**Self-review:** All proposed changes fit the five-file allowlist; assertions cover semantic identity, AX target and physical route. No product repair or UI omission is implemented by this plan. Execution remains in the existing task/branch after approval; no extra worktree or execution-method choice is required.

**Observed outcome:** native run 39706894019 on 34d15f0 built and ran all three controls; each retained two AX failures, and all three coordinate routes passed. Neither omission resolved the issue. All controls were removed in 06591d1. Further nonvisual candidate evidence is tracked in tasks/ui-integration-test-alignment-20261021.md; the full integration gate remains pending.

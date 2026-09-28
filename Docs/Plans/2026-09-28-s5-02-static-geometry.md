# S5-02 Static App Space Geometry Implementation Plan

> Execute inline with superpowers:executing-plans and test-driven-development; one fresh whole-branch review after GREEN. User continuation on 2026-09-28 authorizes the next slice after S5-01 integration/main CI.

**Goal:** Validate the right-biased Current and left history stack using pure local geometry and DEBUG-only samples.

**Architecture:** AppSpaceGeometry consumes local viewport/safe-area values, caller-owned ordered identifiers, Current identity and typography-derived minimum dimensions. It returns value-only frames, depth and corner radius for Current plus at most three previous items. The New sentinel is appended once at the logical right end. No owner, database, runtime, navigation gesture or real catalog is introduced.

**Tech Stack:** Existing iOS 26/Swift 6 strict concurrency, UIKit geometry, SwiftUI DEBUG fixture, Swift Testing/XCTest; no dependency/settings change.

**Spec:** Blueprint `596a84d4b58769e3e7b838be95edcb43f9e0ec82`, App Space/Split/navigation §§1/4/5; Stage 5 index/CONTEXT; Desktop Stage5 plan §5 S5-02. Base `d68195ed6b963f2380b1548ae47f6642852252c8`; main CI36378968995 attempt1 passed 662 Swift Testing/104 suites,20XCTest units,5UI tests. Device checks remain pending.

## Global Constraints

- Keep one existing Composer/reading owner; this slice never instantiates them.
- No real catalog, gestures, New creation, ordering writes, runtime/provider/persistence changes, shader/parallax or Split/orientation policy.
- Safe local viewport values only, no UIScreen. Invalid/nonfinite/overflowing geometry or duplicate/missing identity returns nil, not fake data.
- Inputs remain caller-owned; output order is historyIDs followed by one New sentinel. Sorting/activity semantics arrive in S5-04/06.
- Initial width/height ratios .82/.74, horizontal center .56, depth scales1/.96/.92/.88, offsets up to28/6 and corner24 are calibration values from the Blueprint. Clamp for available bounds and typography; they are not immutable product rules.
- Current minimum dimensions are supplied by the caller (DEBUG baseline220×300, scaled with Dynamic Type). Fit within safe bounds when a minimum cannot fit. Tiny bounds prioritize containment over text legibility; this is not minimum-size product acceptance.
- No portrait policy is imposed on landscape; pure geometry remains finite/contained, formal App Space landscape remains a later product decision.
- Keep generated project ignored, Config unchanged, GRDB confined to Persistence. Preserve earlier records.

## Interfaces and file whitelist

- Create `App/Workspace/AppSpaceGeometry.swift`: Item conversation(String)/newConversation; Placement item/frame/depth/cornerRadius; Layout safeViewport/logicalOrder/cards; resolve(size:safeArea:historyIDs:current:minimumCardSize:) -> Layout?. Depth0 Current,1...3 previous; cards returned back-to-front. New remains logically right even when not rendered in the bounded previous-only stack.
- Create `Tests/ZenAgentTests/AppSpaceGeometryTests.swift`: literal baseline, left/depth ordering, New/empty history, Dynamic Type minimum changes, viewport/safe-area matrix, invalid identity/nonfinite/overflow,1000-ID window budget.
- Create `App/Workspace/AppSpaceStaticGeometryFixture.swift`: lightweight sample text/solid cards, no business status or action, local safe GeometryReader viewport and scaled minimums. GeometryReader is already inside the system safe area; pass zero extra inset to avoid applying it twice. Unit tests exercise explicit insets.
- Modify `App/ZenAgentApp.swift`: DEBUG launch routing only; deterministic New/large-type fixture environments.
- Create `Tests/ZenAgentUITests/AppSpaceGeometryUITests.swift`: shape/depth/containment, New as Current, Dynamic Type fit, no text editor; normal launch remains existing Conversation shell.
- Update README status and append historical S5-01/entry evidence; add slice record under tasks. No other source edit.

## Task 1: Pure geometry, RED then GREEN

- [ ] Write tests with literal400×800/insets10,20,30,40 baseline: safe340×760, Current278.8×562.4 at center210.4,390; verify right bias, Previous left/top/decreasing size and contained bounds.
- [ ] Pure-new exception: no baseline API exists. Supply a compilable deliberately centered/full-size/same-depth mutation with wrong New order and missing rejection; CI must execute the behavior assertions and fail. Compiler failures do not count as RED.
- [ ] Implement validation and the minimum bounded stack. Resolve minimum dimensions against available bounds and constrain history offsets. No new ownership/failure callback path; invalid request returns nil, existing visual owner can retain previous presentation later.
- [ ] Run complete CI; preserve exact candidate/run/attempt/counts. Commit only whitelisted files.

## Task 2: DEBUG samples and real UI verification

- [ ] Add DEBUG route and static fixture using the same resolver; no new normal-user entry.
- [ ] UI tests observe Current right bias, historical width/left exposure, containment/New and accessibility Dynamic Type. Labels identify static sample content only, never fake persisted Conversations.
- [ ] Run XcodeGen/App build/whole tests in CI; exact source tree must match PR merge tree.
- [ ] Fresh whole-branch review, resolve Important findings with real behavior RED/GREEN. Integrate after review/full CI, then main CI. No device or performance claim without device evidence.

## Review Focus

1. Safe-area already applied versus explicit insets; resized/short/tiny viewport remains finite/contained.
2. Large text minimums cannot push Current or history outside bounds; full product text usability remains device acceptance.
3. Caller identity/order untouched; duplicate/missing IDs rejected and New always exactly once/rightmost, including empty history.
4. Bounded geometry window independent of1000 histories; no claim that this delivers real preview virtualization.
5. DEBUG bypass contains no editable Composer/Pane or business effect; normal launch and existing keyboard/reading regressions stay intact.

# Split keyboard layout repair — 2026-10-18

Owner-approved scope: unify keyboard avoidance and animation for two occupied
Panes and Conversation plus picker. Retain drafts, reading ownership and the
stored Split ratio. No packaging or full test run in this iteration.

Baseline: `f12cb87be247cd3cd5cf54743bdeea68f92a8e50`, with this chat's existing
uncommitted Sidebar/Lift repairs retained on `codex/split-keyboard-layout-20261018`.
The unrelated `deep-reading-native-trace.txt` is not an edit target.

## Implementation ledger

1. Keep the existing outer keyboard-adjusted workspace as the sole avoidance
   boundary. Disable `.keyboard` safe-area contribution in the nested Split
   hosting controllers, including the picker host.
2. Resolve one `SplitWorkspaceGeometry` for each workspace layout. Pass its exact
   viewport sizes to the retained native Surfaces, and update their bounds and
   pinned content in the current SwiftUI representable animation transaction.
3. Give each clipped Surface an opaque canvas matching its content, so a delayed
   content redraw cannot expose the black structural background.
4. Add native ownership/coverage and UI state-retention regressions. Run local
   static checks; record native compilation/testing as pending.

Ruling: reuse the existing outer SwiftUI keyboard transaction and Apple's
`UIViewControllerRepresentableContext.animate(changes:)` bridge. This preserves
the mounted Pane/Composer hierarchy and the existing keyboard animation source.
No fixed keyboard duration, new conversation/session owner or ratio mutation is
introduced. Native intermediate-frame coverage remains an acceptance requirement.

## Source and verification status

- Added a workspace viewport contract to the retained native Surface. Split hosts
  and the picker remove only `.keyboard` from their hosting safe-area regions;
  Single and App Space restore the existing native behavior.
- One geometry snapshot now supplies both Surface sizes, the picker and Divider.
  `context.animate` applies native bounds/content layout in the same transaction.
  Conversation and picker canvases use their respective content background colors.
- Added `SplitKeyboardLayoutTests` for native viewport/host identity and exact
  partition coverage, plus `SplitKeyboardUITests` scenarios for repeated
  keyboard cycles, non-default ratio, drafts, native input identities and the
  source reading anchor. Existing reading/resize ownership code is retained.
- `git diff --check` and static reference/ownership checks passed. A numerical
  cross-check of 36 viewport/ratio combinations retained complete coverage and
  the input ratio. This cross-check is not Swift or UIKit test execution.
- Swift/XcodeGen are unavailable locally. No native suite, full CI, package,
  push or merge was run. Keyboard animation intermediate frames, device behavior
  and the added native/UI regressions still require native verification.
- Independent focused static review found no concrete implementation defect.
  The UI regressions inspect settled geometry; intermediate-frame coverage and
  rapid keyboard retargeting still need native frame sampling before acceptance.

API references checked for this implementation:

- https://developer.apple.com/documentation/swiftui/uihostingcontroller/safearearegions
- https://developer.apple.com/documentation/swiftui/uiviewcontrollerrepresentablecontext/animate(changes:completion:)

## Follow-up avoidance and animation audit — 2026-10-18

- Traced both occupied Pane hosts, the picker host, shared Composer dock and
  Timeline clearance in both keyboard directions. Split uses the proposed
  workspace size directly, without subtracting GeometryProxy keyboard insets.
  Nested hosts exclude `.keyboard` throughout show/hide; the dock's root-guide
  conversion corrects coordinates rather than subtracting keyboard height again.
  Timeline bottom clearance reserves the measured Composer, not another keyboard.
- Found an animation-scope risk missed by the earlier focused review: Divider
  and dock used a broad Sidebar `.animation(..., value: sidebarProgress)`.
  A Sidebar progress change concurrent with keyboard dismissal could assign the
  Sidebar's 0.22-second timing to keyboard-driven geometry as well. Confined that
  animation to horizontal `.offset` using `animation(_:body:)`; Split sizing and
  Divider position retain the incoming keyboard transaction. This is a source
  scope correction, not a reproduced native animation result.
- Extended the UI test matrix to both source placements, both occupied input
  owners, repeated show/hide, full restoration of both frames and Divider,
  Composer-to-keyboard gap, plus Sidebar-triggered dismissal. Draft, native editor
  identity, reading-anchor tolerance and ratio assertions remain in place. The
  geometry assertions now wait for a coherent endpoint, rather than treating
  keyboard existence as evidence of completed layout.
- A focused static scope guard failed before the scope correction and passed
  after it. This is not Swift/XCTest RED-to-GREEN. No native test or build was
  executed; tests still inspect endpoints, not animation intermediate frames.
  Interactive dismissal, interrupted/rapid retargeting and simultaneous native
  Sidebar/keyboard presentation still require device or simulator frame sampling.
- No controller/editor replacement, draft write, reading correction or Split
  ratio write was introduced by this follow-up. No package, push or full test run.

Additional Apple reference checked:

- https://developer.apple.com/documentation/swiftui/view/animation(_:body:)
  explicitly limits the supplied animation to modifiers inside its closure.

## Rapid reversal and overlapping Sidebar audit — 2026-10-18

- Found another concrete ownership collision: native Sidebar settlement animated
  `Surface.center`, including the old vertical center, while keyboard layout also
  wrote that same center. Sidebar interruption additionally copied the complete
  presentation position back into the model. The earlier scoped SwiftUI modifier
  correction did not address this native property overlap.
- Added a retained ancestor for Sidebar's horizontal transform. Keyboard layout
  exclusively sizes/recenters that ancestor and the Surface; Sidebar animates
  only the ancestor transform, shadow alpha and appearance. Lift continues to
  own the Surface transform. Both conversation hosts and picker hosts use this
  boundary. Native hit routing now converts through the complete presentation
  hierarchy, keeping exposed Rail space pass-through. Content/editor roots,
  reading owners, drafts and stored Split ratios are unchanged.
- Added a native regression that pauses Sidebar opening, repeatedly reverses the
  workspace height, reverses Sidebar settlement and checks the retained content,
  separate transform ownership and rejection of the interrupted completion. It
  covers conversation and picker canvas colors. Existing Sidebar assertions now
  check the actual rendered offset instead of an internal center implementation.
- Added opt-in DEBUG `ZEN_SPLIT_KEYBOARD_STRESS_UI_TEST` instrumentation. Twelve
  native focus requests run 60–90 ms apart inside the app, so XCTest's idle waits
  cannot silently serialize the stimulus. CADisplayLink samples presentation
  geometry for Surface/content coverage and the two-host workspace partition.
  A separate five-second Watch records the real edge-gesture/keyboard-dismissal
  overlap. Sampling records missing hosts, maximum gaps, keyboard retarget events
  and Sidebar-present samples; it has no draft/user-text output and never drives
  production layout. Dismantling cancels the task, notifications and display link.
- All four placement scenarios now require actual keyboard overlap during rapid
  requests and actual Sidebar/keyboard events during Watch. A zero-sample or
  non-overlapping run fails rather than claiming coverage. Endpoint draft/editor
  identity, reading anchor, ratio and restored-frame assertions remain in place.
- Focused source guard detected the overlapping center writer before correction
  and passed afterward; diff formatting and diagnostic wiring checks passed.
  These are static checks, not Swift/XCTest execution. Independent focused review
  found no concrete container/hit-routing/completion defect. It identified two
  sampler gaps, now addressed: horizontal edges are checked against the host in
  keyboard-only runs and the translated ancestor in Watch (including equal Pane
  travel); Watch must record a joint display tick containing Sidebar transport
  within UIKit's reported keyboard transition timing. Separate nonzero event
  counters alone no longer count as evidence of overlap.
- No local Swift, XcodeGen or Xcode is available; no package, native build/test,
  full CI, push or merge was run. The new sampler is authored but unexecuted, and
  measures geometry, not black pixels or actual rendered keyboard pixels. Device
  or simulator execution/video remains required before asserting absence of black
  frames or animation conflict, especially under interactive keyboard dismissal.

## Owner-approved focused native execution — 2026-10-18

- Owner authorized only keyboard/Sidebar focused tests, with no package or full
  suite. Added `workflow_dispatch` selection `test_scope=keyboard-sidebar` to the
  existing CI workflow; its full build/test and iPad jobs are skipped for that
  selection. The cheap repository hygiene job remains a prerequisite.
- Candidate `7df054a52e55f3f3231dbb8c6529fc101403625b` was pushed with `[skip ci]`
  to avoid automatic full runs, then explicitly dispatched as
  https://github.com/54zhien/Zen-Agent/actions/runs/39095451685 .
- Selected native suites: SplitKeyboardLayoutTests, SidebarSurfaceTests,
  SidebarDecorationTests, WorkspaceNavigationStateTests and
  ComposerMotionControllerTests. Selected UI tests: the four SplitKeyboardUITests
  placement scenarios, plus stable-editing dismissal, shifted blank-tap closure
  and occupied Split opposite-pane/shared-input closure. No test retry is enabled.
- The scoped runner generates/builds for the simulator, records the selected UI
  run, and uploads result bundles, summaries, attachments, logs, selectors and
  candidate SHA. Split pressure metrics are retained as XCTest attachments and
  console output. Execution result and video inspection are pending.

### First focused native result (retained RED)

- Run 39095451685 at `7df054a` generated and built successfully on Xcode 26,
  iPhone 17 Pro simulator / iOS 26.4.1. The five native suites passed: 23 tests
  (32 parameter-expanded executions), no failures/skips. UI: 7 executed,
  2 passed / 5 failed, no skips. Original result bundle, logs and video remain
  in that run's artifact; local copy is under `.tmp/keyboard-sidebar-run1/`.
- Completed rapid samples recorded 12 keyboard notifications and 5–6 retargets,
  no missing hosts, maximum Surface/content boundary error below 0.17 points,
  partition error at floating-point zero. This does not make the failing UI run
  green, nor establish the scenarios that did not reach sampling.
- Diagnosed invalid test measurements: inactive parked editors have no mounted
  native identity; an AX ScrollView rectangle can extend beyond a lower Pane;
  the Divider's AX hit region is taller than its visual gap; and a closing-tap
  helper still requested a keyboard rectangle after Sidebar had dismissed it.
  Identity assertions now run when each original owner is mounted again; taps
  use the measured native readable viewport; geometry uses the visual Divider
  center/gap and a DEBUG window-coordinate keyboard guide. No geometry tolerance
  was increased. Reading labels are checked by their real viewport intersection
  and the existing four-point position tolerance, not AX activation-point support.
- A five-second Watch expired before the real gesture in one run (0 keyboard
  events). Watch now arms without a display link, starts sampling on the actual
  keyboard notification and ends one second after the last notification, with a
  bounded no-event watchdog and generation-checked cancellation. Joint overlap
  assertions remain mandatory. The original failed Watch is retained as evidence.
- These follow-up edits change test stimulus/measurement and DEBUG diagnostics;
  the retained production keyboard/Sidebar transport is unchanged. A fresh run
  of the same explicit unit/UI selection is required.

### Follow-up candidate and first-video inspection

- Follow-up candidate `3f3a4c1d6d7500eaf334c6ffa1ddcb418337cc7d` is running the
  same explicit selection in
  https://github.com/54zhien/Zen-Agent/actions/runs/39097014305 . Both full-suite
  jobs remain skipped. No package job was started.
- Decoded all 6,580 captured frames of the first simulator recording and inspected
  representative contact sheets/endpoint screenshots. A whole-video heuristic
  scan at 240×522 found no large nearly-black central band/candidate (RGB<12,
  >14 reduced-pixel contiguous band or >6% central black area in light-content
  frames). Maximum continuous near-black band was three reduced pixels. Local
  scan evidence: `.tmp/keyboard-sidebar-run1/pixel-review/summary.json`.
- This is limited to the captured light-fixture simulator frames and the stated
  heuristic; it does not prove every display tick or physical device behavior.
  Video creation metadata was not a precise first-frame wall clock, so temporal
  evidence relies on the whole recording rather than the initial approximate
  phase-to-wall-clock windows. The first UI run remains failed.

### Second focused native result (retained RED)

- Run 39097014305 built candidate `3f3a4c1` successfully. All 23 native tests
  (32 parameter-expanded executions) passed. UI: 5/7 passed, no skips; the three
  Sidebar regressions, source-top dual Conversation and source-top+lower picker
  scenarios passed. Full and iPad suites were skipped; no packaging ran.
- Picker-above/source-below reached rapid and Sidebar overlap sampling with no
  missing hosts, <0.17pt underfill and zero partition error, but reading restoration
  failed and Watch yielded only four ticks. Dual Conversation/source-below failed
  activation after the initial Divider resize, before its stress sequence.
- Follow-up measurements now wait for actual native Divider resize receipts before
  attempting focus, attach both native pane diagnostics and the Divider state, and
  compare reading distance using the same native readable viewport at baseline
  and restoration. AX ScrollView bounds are not a clipped reading boundary.
  The four-point reading tolerance remains unchanged. These changes require a new
  native result and are not evidence that the remaining failures are resolved.
- Watch observes two seconds after the keyboard event, extending only to collect
  six real display ticks within a five-second bound. It no longer adds a synthetic
  final sample; keyboard/Sidebar joint-overlap assertions remain mandatory.

### Third focused native result and bounded lease repair

- Run 39098874606 at `e3cb053` generated and built successfully; 23 tests / five
  native suites passed. UI: 4/7 passed, no skips. Both source-top Split cases and
  two Sidebar regressions passed. Full/iPad jobs remained skipped; no package ran.
- Native receipts confirm the source-below resize transaction is stuck at revision
  3 (accepted/measured/ready), actual offset 1736 versus requested 1759, content
  height 2042 and readable height 283. Both lower-source arrangements retain the
  lease. A pending same-sequence request cannot reissue, while bridge completion
  requires its target and nil request. 1736 exactly matches the preceding 306pt
  viewport's bottom; this is consistent with an early native command being clamped.
- Picker-above/source-below also showed actual reading-anchor displacement around
  56pt after keyboard cycles while that resize lease remained active. It is not
  dismissed as an AX measurement problem. First repair the confirmed transaction
  deadlock and rerun the same placement/reading assertions.
- The bounded repair clears only the applied-command marker when a native viewport
  height changes during an existing Divider lease. It retains the logical request,
  target and strict acknowledgement; the new native viewport can reissue it.
  Keyboard transport outside a Divider transaction is unchanged. Native execution
  must establish whether SwiftUI accepts the same numeric target again.
- The stable-editing Sidebar regression also failed once: admission returned true
  with matching owner, but UIKit delivered no recognizer action callback and the
  edge returned to possible; neither detach nor navigation begin/dismiss occurred.
  It passed in the first two runs. Root cause is unconfirmed; enrich peer/state
  diagnostics and retain it in the same no-retry selection, without changing
  gesture policy based on this single observation.
- Completed rapid/Sidebar samples had no missing hosts, <0.17pt underfill and zero
  partition error; Watch now captured 100-111 real ticks with joint overlap. This
  does not make the failed UI selection pass.

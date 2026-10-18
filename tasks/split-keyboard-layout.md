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

### Fourth focused result — audit remains RED

- Run 39100303428 at `37f6482ab315ef4eeb0f7844fb6beaccc6ff935e` built
  successfully and passed all 23 selected native tests (32 expanded executions).
  UI summary: 7 executed, 3 passed, 4 failed, zero skipped. Full/iPad jobs were
  skipped; there was no archive, signing/export or packaging action.
- Source-top dual Conversation and Conversation+lower picker again completed
  rapid reversals and actual Sidebar keyboard dismissal. The stable-editing
  Sidebar case passed this time. Each completed rapid sequence delivered all 12
  notifications and six retargets; no hosts were missing, max boundary error was
  below 0.17pt, and partition error was floating-point zero. These are geometry
  samples, not a claim about every rendered pixel.
- The source-below Divider lease still did not release. In picker-above mode its
  measured offset reached 1754 versus target 1759; in dual Conversation it remained
  1736 versus 1759. Reading restoration still displaced the anchor about 56pt.
  Dual Conversation/source-below never reached its pressure sequence because the
  initial focus switch was blocked. Required placement coverage is incomplete.
- Two additional Sidebar regressions failed: shifted blank-tap close succeeded,
  but reopening the editor/keyboard timed out; the occupied-Split Sidebar case
  could not enter its Split picker. These are retained as failed native results,
  not waived or retried into a passing aggregate. Their causes remain unconfirmed.
- Withdrew the unsuccessful lease-only pending-marker retry. It did not establish
  correct restoration and is not left as a claimed fix. Keep the explicit resize
  receipt assertion, bounded probes and peer/state diagnostics for the next repair.
- Source SHA, summaries/tests JSON and attachment manifest are retained locally in
  `.tmp/keyboard-sidebar-selective4/`; complete result bundles, logs and recording
  remain in run 39100303428's artifact. The fourth recording has not received a
  full pixel review. Earlier whole-video heuristic scans of runs 1-3 found no
  large nearly-black band, but do not cover the blocked pressure sequence or
  establish physical-device acceptance. No clean keyboard/Sidebar acceptance is
  claimed from these failed runs.

## Owner-authorized repair of focused native failures — 2026-10-18

- Continue from retained RED runs 39098874606 and 39100303428. Prior viewport-only
  pending-marker retry was measured ineffective and withdrawn; do not revive it
  as a claimed fix. Preserve the lower-source resize/focus/reading assertions.
- Smallest repair boundary: Timeline owns a weak native viewport reader inside
  its ScrollView content. Only a live Divider lease may use it to send normalized
  pixel offsets, after actual UIKit usable height and content size match the
  current reading geometry. Top inset is subtracted exactly once. No polling,
  delayed commands or replacement of the retained ScrollView/Composer is added.
  Ordinary keyboard/reading continues using the existing ScrollPosition path.
- Native command acceptance is not completion. Keep the existing model request,
  strict measured-target acknowledgement, final layout revision and owner receipt
  as the only lease-release path. A pending lease may retry against newer native
  geometry; an already-reached native offset does not cause another write.
- Weak anchor ownership prevents an old unmount from clearing a newly bound
  ScrollView. Off-window or stale-content/viewport commands are rejected and wait
  for the next real geometry/measurement callback. Cancellation still belongs to
  the existing Divider lease/controller, with no queued native command to cancel.
- Add three native viewport regressions (including top-inset parameter cases),
  retaining all seven focused UI cases and adding the new class to the explicit
  runner. The runner expects 26 declared native tests and seven UI tests.
- Keyboard reopening and Split entry still need conclusive failure-state data.
  Enable bounded existing Composer dock trace for the preview fixture; retain
  focus/tap outcomes and full native Sidebar receipts, plus a failed entry probe.
  This changes observability, not UI stimulus, wait times or acceptance tolerances.
- Blueprint index/CONTEXT and App Space/Split note were checked in the local
  Blueprint checkout (596a84d). Divider bottom anchors, independent Pane owners,
  reading/draft retention and shared visual Composer remain the intended behavior.
  No design change or hard-to-reverse engineering decision is introduced.
- Windows static checks passed (`git diff --check`, workflow YAML parse). Native
  generation/build and scoped tests remain required; this edit is not yet a fix
  verified by a fresh native run.

### Preflight review corrections before native execution

- Initial candidate f646321/run 39102227210 was cancelled before a complete native
  result. It is not counted as build/test success. Review identified a combined
  subpixel reachability bound and a missing guaranteed retry when UIKit layout is
  later than SwiftUI geometry.
- Check the target against the actual normalized native maximum within the same
  0.5pt receipt tolerance; reject the 1759.8-vs-1759 unreachable composite-error
  fixture rather than broadening acknowledgement. Clamp only a <=0.5pt endpoint
  rounding difference to the actual native maximum.
- Superseding the no-polling draft above: retain at most one current Divider pixel
  command while native metrics catch up, with a two-second display-link wait in
  common mode. A weak proxy prevents run-loop ownership of the viewport. Success,
  cancellation, changed anchor/scroll/window identity, nil model request and lease
  release stop the link. LeaseID/request-sequence validity is read from the weak
  bridge before every attempt. Expiry stops work and records a bounded diagnostic;
  a later real layout/request event may resubmit, without treating expiry as success.
- Repeated submission of the same still-current target/geometry retains its wait
  deadline. A command ID prevents a synchronous native callback from letting an
  older completion cancel a replacement command.
- The fourth viewport regression uses a real CADisplayLink tick: late 414→391
  bounds apply without a second helper call, while a cancelled lease never moves
  the native offset. Strict selection now expects 27 native declarations / seven
  UI cases. These additions and all repairs still require native execution.

### Fifth focused result — Divider repaired, reading remains RED

- Run 39102591056 at `5226b32a27353b9e8a6e6347dc81590cb9107dd9`
  generated/built successfully; all 27 selected native declarations passed.
  Seven UI cases executed, five passed, two failed, zero skipped. Full/iPad jobs
  were skipped; no archive, signing/export or packaging ran.
- Both lower-source placements now reached offset 1759 and released the Divider
  lease, with zero native command wait expiries. All four Split placements reached
  rapid keyboard reversal and actual Sidebar/keyboard overlap sampling. This
  resolves the previously blocked coverage, not the independent reading failure.
- Picker above/source below still displaced the reading label from y593 to about
  y536.3. Dual Conversation/source below repeated that displacement and drifted
  further when the other input owner was activated. Keep the original four-point
  assertion; do not classify model-anchor drift as a screenshot-only discrepancy.
- All three Sidebar cases passed this run. Earlier intermittent reopen/entry
  failures remain evidence; one passing execution does not establish their cause.
  Extend the existing reopen case through the subsequent production Split drag.
- Next diagnostic retains bounded height transaction capture/continuation/end
  events alongside the existing reading trace, and records state immediately after
  rapid reversals. It changes neither UI stimulus nor acceptance tolerances.
- Summaries, test trees, source SHA and attachment manifest are retained in
  `.tmp/keyboard-sidebar-selective5/`; full bundles/logs/video remain in the run's
  artifact. A fifth-recording pixel review is still outstanding.

### Native diagnosis of repeated lower reading drift

- Run 39104266338 (`4d46b67`, diagnostic-only candidate) retained the decisive
  Picker-above trace: a capture of 4.431327 points, normalized for viewport 221,
  is cleared at native viewport 102.666667 before the reading reduction. The next
  begin multiplies that old ratio by the smaller viewport, reducing the capture
  to 2.058596, then 0.956331 and so on. This is state drift, not AX-only geometry.
  It generated/built successfully, passed 27 selected unit declarations and five
  of seven UI cases (zero skipped); only the two lower-source reading cases failed.
  All three Sidebar cases passed again. Complete summary/test trees and UI.log
  are retained in `.tmp/keyboard-sidebar-selective6/`.
- A separate earlier trace shows an inherited height transaction started while
  following bottom and still held nil reading pixels after the older Turn was
  restored at viewport 283. Retaining that nil forever would only hide drift at
  the final endpoint; the reading pixels need to be captured once when present.
- Repair boundary: programmatic scroll idle may end a Composer height capture
  only after the current reading mode and both native viewport observations
  (published snapshot and phase context) match the last processed height reduction.
  Each new Composer mark invalidates that reduction proof. The announced height
  must actually change before an unchanged Preference pass can certify completion;
  idle before the first resize retains the mark too.
  User scroll idle may supersede it; Divider idle cannot cancel its independent
  receipt. Explicit user scrolling, Divider begin/cancel and presentation changes
  retain their existing cancellation paths. A first materialized reading mode
  supplies a missing pixel baseline; repeated notifications retain that baseline.
- Three regressions reproduce native-arrival-before-reduction idle ordering in
  both callback orders, mark-before-first-resize and same-height retarget ordering,
  unchanged Preference rejection, coherent final idle completion, same-height changed-mode
  rejection, missing reading baseline, and Divider idle isolation. Select the existing eight
  bridge tests too: 38 declared native tests and the same seven UI cases, only.
- Extend Sidebar reopen through a subsequent real Split drag, and all four Split
  placements through Sidebar close/reopen/dismiss plus reading/draft/ratio checks.
  No acceptance tolerance or timeout was broadened.
- Fifth video: decoded all 8,824 frames with the existing central light-fixture
  near-black-band heuristic; no candidates, max band three reduced pixels. Selected
  contacts include both lower placements with keyboard shown/hidden and filled
  surfaces. Phase-to-video wall-clock mapping is approximate and is not used to
  make per-transition timing claims. This does not waive the failed reading tests.

- Candidate `93cc192` / run 39106095659 stopped at test compilation: Swift
  Testing's expanded `#expect(beginDividerResize(... closure ...))` passed a
  non-Sendable macro parameter into an actor-isolated callback. Evaluate admission
  before asserting its Bool, as the existing Divider regressions do. No test was
  executed in that run; it supplies neither UI acceptance nor a passing build.

### Further cancellation boundary found after native replay

- Run 39106721530 at `1941003` built and passed all 38 focused unit declarations.
  The three Sidebar cases (including the newly extended reopen→Split drag) and
  source-top Conversation+picker case passed. Partial native evidence still
  reproduces lower-picker y593→536.3 reading drift; numerical reduction guards
  alone have not repaired it. Preserve this RED rather than treating unit green
  or the extended Sidebar pass as complete acceptance.
- Re-audit found an independent path: Timeline's combined visibility/revision/
  usable-geometry guard marked `readingGeometryWasSuspended` for any unusable
  ScrollView sample. Its next valid sample ends the capture, drops pending native
  bookkeeping and requests geometry restoration before height continuation.
  The old trace has no call-site reason, so this remains a candidate cause until
  the next native replay; do not attribute its `end` conclusively to idle.
- Split the guard: unchanged attachment/revision plus unusable geometry is a
  missing sample and leaves the last valid reading/capture intact. True visibility,
  ownership or layout changes retain suspension/resume cleanup, including when
  their first geometry is unusable. No geometry, offset or tolerance is fabricated.
- Add bounded debug gap reasons, idle provenance and compiler-provided end-call
  locations to distinguish this path from genuine user scrolling or Lift return.
  Keep the same 38 unit declarations and seven strengthened UI cases.
- Complete run 39106721530 result: native build and all 38 selected unit
  declarations passed; UI 5/7 passed, zero skipped. Both lower-source reading
  cases remain RED, including the extended Sidebar-close/reopen reading check.
  All three Sidebar cases and both upper-source Split cases passed. Full UI.log
  and native summary are retained in `.tmp/keyboard-sidebar-selective8/`.

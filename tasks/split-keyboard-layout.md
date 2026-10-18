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

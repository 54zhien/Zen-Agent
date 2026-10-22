# Proposed Sidebar native-host visibility diagnostic

**Status: visibility control finished and removed; nonvisual role follow-up pending.**

The owner froze UI and requires a stop before UI-affecting changes. Existing
permission covers test adaptations, narrow nonvisual interaction diagnosis, and
the earlier specific style/mask controls. This proposal has a different visible
effect and was therefore presented separately. The owner authorized temporary
page hiding, further root-cause diagnosis and restoration after testing; finalized
product UI remains frozen.

## Evidence and question

The unchanged Rail passes a semantic tap in isolation at the exact production
Settings frame. Full-page baseline retains the original AX failures. Independent
style and mask omissions, page hit suppression and fixture reading-control
omission did not solve them. SwiftUI page AX omission did not actually remove the
native subtree, so it cannot exclude that boundary.

Question: does removing the retained native foreground page from rendering and
AX after Sidebar settlement restore the unchanged Rail's semantic hit target?
This is a diagnostic, not a proposed product behavior or established root cause.

## Exact visible impact

Only a DEBUG test process with a new explicit launch flag would hide the native
foreground conversation host after Sidebar is fully open and settled. The
conversation page, Composer, and host-owned decoration would temporarily vanish;
the unchanged Rail and remaining App Space background would remain. Opening
animation runs normally before hiding. Closing clears the diagnostic override.
Route entry also clears that override; ordinary overlay visibility remains
authoritative, and the host returns through its existing dismissal path. No
style, geometry, press spring, haptic trigger or route is replaced.

The host/controller/content stay retained; do not remove/recreate them or change
their model, layout, transform, reading position, editor or navigation state.
Never interpret this temporary disappearance as an acceptable final UI fix.

## Scope and checks after approval

- `App/Workspace/ConversationSurfaceHost.swift`: DEBUG-only visibility control at
  the host boundary. Gate on positive settled Sidebar progress, reset on closing,
  cancellation, return, disappearance and flag absence. Audit existing visibility
  ownership so normal workspace/return visibility is never overwritten. Use an
  independent diagnostic visibility gate: do not call or replace
  `setWorkspaceVisible`, whose ordinary overlay path resigns the editor and
  detaches hosted content. That path remains authoritative on real route entry.
- Existing DEBUG native receipt: report diagnostic mode plus actual host hidden
  state and frame. Confirm the expected visible/AX omission actually occurred.
- `Tests/ZenAgentUITests/SidebarUITests.swift`: separate baseline and flagged
  launches, retaining unique/spoken name/enabled/frame/hittability/real Settings
  route assertions and before/after screenshots plus AX snapshots. Add explicit
  omission verification and restoration checks; a failed precondition makes the
  control inconclusive. Baseline must retain RED for causal interpretation.
- `.github/workflows/ci.yml`: select only these diagnostic cases in the focused
  profile. Do not run class-selected/full integration with variants present.
- Run local syntax/hygiene checks, push exact source, run real XcodeGen/build and
  tests in macOS CI, and preserve every failure/artifact digest.
- Remove every flag, visibility override, extra test and temporary selector after
  collecting evidence. Verify product byte equality with frozen `eb39a65` before
  considering a separately reviewed minimal repair. A successful diagnostic is
  not a successful integration gate.

## Failure and cancellation

If the run fails, times out, or the host does not actually disappear, preserve
that result and restore diagnostic source. Do not weaken existing assertions,
keep the page hidden as a fix, merge, or start S6 on diagnostic success alone.
Production UI changes beyond this specific temporary omission still require the
owner's separate direction.

## Nonvisual follow-up after visibility restoration

Independent review and the native snapshots identify full-phase card Button
traits around the actual conversation despite `isAccessibilityElement=false`.
The task record contains the observation and its causal limits. After restoring
all visibility code in `c91e76f`, run a separate DEBUG control that changes only
the full-phase Surface trait from `.button` to `[]`. Leave its label/hint,
hierarchy, physical hit-testing and all pixels unchanged. Require a native trait
receipt and disappearance of the exported full-page Button role, preserve native
pane/editor/identity and every original Settings assertion, and add a semantic
Settings re-entry only after the control and coordinate/hit checks pass. An
ineffective exported-role omission is inconclusive. Remove the flag, extra case
and temporary profile selection after native evidence; cleanup base `c91e76f`.

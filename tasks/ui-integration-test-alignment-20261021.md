# UI integration test alignment — 2026-10-21

The owner finalized the current UI, authorized test-only adaptation and diagnosis,
and requested direct merge after a passing gate, followed by S6. Product UI must
remain unchanged; any required product correction stops for an impact explanation.

## Frozen product and original evidence

- UI baseline: `eb39a65d98116fbd53dccd6ba43cd9e685e8151d`;
  tree `f811529a766980a1f22b0bbccf87e2a0e5f89d79`.
- Integration PR: https://github.com/54zhien/Zen-Agent/pull/37.
- Original full run: https://github.com/54zhien/Zen-Agent/actions/runs/39619632065.
  Hygiene, generation, actual build, all 1,140 Swift Testing cases / 171 suites,
  20 XCTest unit cases and the actual iPad axis case passed. Native Phone failures
  are real assertion evidence; the whole run is not a passing gate. The final
  workflow conclusion is `cancelled`: the Phone job exceeded its configured
  65-minute limit. Phone did not produce a complete test summary, so no complete
  Phone totals are asserted. The preceding assertion failures remain RED.
- No unchanged retry or cancellation is used to replace that evidence.

## Test ownership and changes

- Sidebar setup explicitly verifies the first edge swipe dismisses raised input
  without opening Sidebar, then uses a separate edge swipe to open it. Search,
  Files and Settings use that setup. Keyboard-free cases retain a single opening
  gesture. A raised-sheet case also preserves editor identity and draft.
- Sidebar readiness includes native animation settlement and actual control
  hittability. A failure retains the native receipt; it is not hidden by another
  gesture, an arbitrary sleep, or a larger timeout.
  First-swipe dismissal also waits for the native closed/settled receipt when
  available, so transient AX absence cannot be mistaken for completed dismissal.
- Thinking tests and App Space geometry are being aligned to the current controls
  and the recorded centered-stack ruling. Split reading/AX failures require
  independent attribution, not relaxed reading-position assertions.
- Manual `ui-integration` CI selects the affected native UI regressions only.
  It is diagnostic verification, not the final full gate; ordinary full selection
  remains intact. No product test fixture, App source, resource, build setting,
  dependency, generated project, animation or UI behavior is changed.

Native verification of the adaptations, final source SHA/tree, full-gate outcome
and merge receipt remain pending. S6 implementation starts only after UI merge.

Focused runs on `e91095da3adbe5aa7686b77ef09826a2b1c75e7e`:

- Lift and unchanged Split reading assertions:
  https://github.com/54zhien/Zen-Agent/actions/runs/39630293867.
- Affected UI integration regressions:
  https://github.com/54zhien/Zen-Agent/actions/runs/39630300120.

These runs do not include the subsequent first-swipe native closed/settled wait.
Their results cannot validate that later change or replace the final full gate.

## Native Split reading diagnosis — 2026-10-22

Run `39630293867` completed **failure** on `e91095d`, with an actual build,
48 Swift Testing cases / 4 suites passing and the three existing Lift UI cases
passing. The unchanged secondary-Split reading case failed three assertions.
No skipped or cancelled run is counted as acceptance.

The exported screenshots establish a visible mismatch before the first Lift:
the test requests Turn 10, but the source Pane displays responses 12–15. The
after-Return screenshot preserves that same incorrect initial placement.
This is not solely an AX query problem. The two matching AX nodes are a TextView
with a null/infinite frame and a second offscreen node at y=-183.67; both are
non-hittable. The later queued Turn 12 is visibly restored, with a finite y=179,
but its assertion inherits the invalid initial anchor frame.

The native reading trace identifies the conflicting requests:

1. Sequence 18 requests `restoreAnchor(preview-reading-run-10, offset: 0.2)`.
2. Lazy materialization supplies Turn 10's measured frame.
3. Sequence 19 replaces it with `maintainBottomEdge(targetOffset: 1451)`.
4. The resulting reading mode points to Turn 16, not the requested Turn 10;
   the fixture reports `settled` once that replacement request is acknowledged.

Read-only follow-up traced the observed conflict to fixture initialization:
`preview-reading-position` is a DEBUG-only overlay that directly changes the
reading mode, bypassing the real ScrollView input path. Real tracking/interacting
input calls `userScrolled`, which ends the prior height-change capture before
capturing the new read. A source swipe cancels the tap gesture rather than
selecting another Split slot, so it can establish that normal precondition while
the secondary Pane retains the shared Composer.

The next test-only candidate adds one real source-pane swipe before deterministic
fixture positioning and explicitly checks source editor count zero / secondary
editor count one. Every existing anchor, Return and queued-hidden restoration
assertion remains. Native verification must demonstrate both accepted scroll
input and unchanged Composer targeting; this source audit alone is not a pass.

A product correction to height/reading coordination would affect Split resizing,
keyboard changes, Divider resizing or reading restoration and remains outside
the authorized scope. No such product change is made. No assertion is relaxed
and no test is skipped to merge. Merge and S6 remain gated on a real passing full
run; the other affected-UI run remains independent evidence to collect.

Artifact `12360617346` contains the result bundle, native logs, video and three
named screenshots. Archive digest:
`sha256:747054a856dd2e0d2cd7a49ccddf27900c5e5140443c7553282d89def9debaa8`.

## Affected-UI result and narrower follow-up

Run `39630300120` ended `cancelled` after its focused job exceeded 40 minutes.
Native assertion failures before the timeout remain RED; no complete UI summary
or result artifact was uploaded. Three App Space geometry cases and the six-level
Thinking detail/persistence case passed. Model switching, Sidebar destinations
and other recorded failures are not waived.

The native model-menu snapshot exposes combined row labels such as
`UI Test Model, 低 · 高 · Max`, rather than just the model name. Model tests now
match the complete name followed by the comma boundary, retaining selection,
three/four-level adaptation and persistence assertions.

The new raised-sheet case omitted the existing `ZEN_KEYBOARD_MENU_UI_TEST`
fixture opt-in; without a configured model, its plus button correctly did not
exist. That case now opts into the same menu-capable preview fixture already used
by the native Split keyboard-sheet test. It identifies the actual sheet and model
row rather than assuming UIKit's Keyboard AX container must disappear for a
custom replacement inputView. Dismissal/ownership/draft checks remain.

Sidebar failures persist even when native receipts report fully open and settled.
Some destinations have invalid AX activation points. Attribution is unresolved;
no product correction is made. The failure helper now retains screenshot and
full AX attachments and prints scoped match counts/frames. A smaller existing
`sidebar-controls` selection covers representative keyboard-free, focused-input,
raised-sheet, Settings and Search cases so failure evidence can finish uploading.
The full test selection and existing wait tolerances are unchanged.

The source-scroll setup candidate `53f3e03` is under native Lift verification:
https://github.com/54zhien/Zen-Agent/actions/runs/39638592284.
It does not include these subsequent model/Sidebar test changes.

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

## Confirmed focused GREEN

- `53f3e0365899c108159814abefce9f99227cecd7`, run `39638592284`:
  actual generation/build and all 48 Swift Testing cases / 4 suites plus 4 UI
  cases passed. The formerly failing secondary-Split case retains every original
  assertion. Before/after Return, the real visible anchor is hittable at y=192.33;
  source/secondary editor counts remain 0/1. The queued hidden request lands at
  y=179.0 against expected y=178.93. Exported screenshots were visually checked:
  anchor 10 remains at the same position before/after Return. No product edit.
  Artifact `12365352609`, archive digest
  `sha256:bce09b25c1514442f9a7cc4b9fba89269d76d5084ce1ff5b10863e6905fa87b6`.
- `de1dbc25adc75be7219c5a9bd9284dbe1d1215f8`, run `39639287417`:
  actual iPad axis UI case passed (1/1, 74.684s). Composer generation/build, all
  1,140 Swift Testing cases / 171 suites, 20 XCTest unit cases and 6 selected UI
  cases passed (`TEST SUCCEEDED`). These include model switching, three/four/six
  Thinking levels, keyboard-sheet transitions and shared-Composer targeting.
  This is a passing focused workflow, not the full gate. Artifact `12366450122`,
  archive digest
  `sha256:d938b7d2287eae9c181ffd05b866fb24db9e7ab7ca7a08ee5a1a93770dbc1adc`.

Current-head Composer and representative Sidebar runs:
https://github.com/54zhien/Zen-Agent/actions/runs/39639287417 and
https://github.com/54zhien/Zen-Agent/actions/runs/39639293598.
The final full gate remains pending.

## Remaining Sidebar RED

`de1dbc2`, run `39639293598`, completed **failure** with a real result bundle:
7 relevant Swift cases passed; 7 UI cases failed with 11 assertions. Settings,
Files and Search each have exactly one enabled AX Button with a finite on-screen
frame: Settings `(34,784,56,56)`, Files `(20,250,56,56)`, Search `(20,130,56,56)`.
Screenshots show the controls visible next to the translated page. Duplicate AX
elements are therefore excluded; a settled native open state and visible pixels
still do not prove actual touch routing or AX target resolution.

Artifact `12364858615` retains screenshots and full AX hierarchies; archive digest
`sha256:a46b0152844a0cfc408c85607c8950b9a48cec66b02d98b74b2b3d9161a551e7`.
Read-only inspection found no conclusive covering view or recognizer in the
available evidence. The next minimal test-only diagnostic preserves the original
hittability failures, then taps once at Settings' finite visible center and checks
the actual Settings route. Settings is clear of the preview fixture's overlay
button near Search, so that overlay cannot confound this touch-path check.
It is separately selectable as `sidebar-hit-path`, so
the original failed tests are not rerun unchanged to replace their evidence.
No coordinate tap is substituted into ordinary navigation tests to waive AX.
No product/UI correction or merge is authorized by this diagnostic result alone.

## UI boundary stop — Settings touch-path result

Diagnostic source `241d940b650496e0e4c166fc420843c868a0fc9f`, run
https://github.com/54zhien/Zen-Agent/actions/runs/39643483481, completed **failure**
after a real generation/build/native run. Its original Sidebar readiness failure
and explicit Settings AX failure remain, and its coordinate route assertion also
fails (one UI case, three assertions):

- Settings exists, is enabled, and has frame `(34,784,56,56)` inside app frame
  `(0,0,402,874)`; AX hittability remains false.
- A single app-level coordinate tap is delivered at visible center `(62,812)`.
- The existing `settings-page` does not appear within the existing 5-second wait.

This excludes an AX-target-only explanation for this observed navigation failure.
It does not identify the precise native interceptor or rule out every routing
condition; no product correction is inferred from a screenshot alone.
Read-only verification confirms the launch supplies a real store and the overlay
coordinator includes `.settings`, creates its model and presents
`SettingsWorkspaceView`. The Settings identifier is therefore a valid destination
in this fixture. The debug reading-position button is far from `(62,812)`.
Before/after screenshots and AX hierarchies were inspected: the visible Sidebar
stays in place and no Settings page appears. The unresolved boundary is product
hit handling, callback delivery or route presentation, not an unsupported fixture.
Artifact `12367455769` retains before/after screenshots, AX hierarchy and native
result bundle, archive digest
`sha256:0c3afa9af9aa54146752639bf92fefa703476d52fd65a38e8123d91a28c84a43`.

Further correction of Sidebar hit testing or event routing crosses the owner's
explicit UI-interaction freeze. Such a correction could alter how taps reach
Sidebar controls versus the translated page and its gestures; layout, appearance,
menu animation and haptics are not authorized edit targets. Product code remains
byte-identical to the frozen `eb39a65` baseline. Stop here for the owner's direction;
do not merge RED, silently waive the hit checks or begin S6 before UI integration.

## Owner-authorized interaction investigation

The owner subsequently answered “允许” to the explicit request to repair only
Sidebar hit testing / event delivery while preserving appearance, layout,
animation and haptics. This supersedes the boundary stop for that narrow scope.
The existing coordinate-route RED stays authoritative. First add DEBUG-only
native window-hit ancestry at two exposed Rail points and record whether the
existing route callback fires; keep all original UI assertions. This gathers a
discriminator before changing routing behavior. Full GREEN and review are still
required before the already-authorized merge and S6 continuation.

### Native hit discriminator and first candidate

Diagnostic `3b36cd7`, run `39646338094`, actually generated/built and finished
one UI case with two retained AX failures. The exposed Settings sample
`(48,811.6)` hits `UIPlatformGlassInteractionView` at `(34,784,56,56)` with a
zero-sized `_UIInheritedView` ancestor; it does not hit the translated Surface.
The actual coordinate tap now calls `settings` with coordinator/eligibility true
and opens `settings-page`. The earlier coordinate-route RED remains recorded:
the diagnostic-only change does not prove stable routing or explain its variance.
Artifact `12368243248`, digest
`sha256:2cc84226f055ed85cf6bd29a6d8f013bfd0c981c019444ea8074225d0f77b67d`.

The remaining reproducible failure is the semantic Button's AX target. The first
single-factor candidate declares the existing 56pt rectangular interaction shape
outside the styled native-glass label, rather than only before glass application
inside the icon. It changes no layout, rendering, spring, feedback, admission or
route. This is a hypothesis under native test, not a claimed repair. Original AX
and real Settings-route assertions remain unchanged.

The rectangular candidate `4fb1f68`, native run `39648934499`, **did not fix**
the AX failure: one case, the same two AX failures, coordinate route true.
Artifact `12370475660`, digest
`sha256:f5c7b8055ea0a426866d664f7181a95742c41fb1d963b45bab8d48590faacaa2`.
Remove that ineffective modifier rather than accumulating changes.

The next isolated candidate fixes each semantic Button's accessibility activation
point to its own relative center, retaining the original content shape and glass.
Apple documents that the default activation point may derive from descendants
instead of the accessibility frame center:
https://developer.apple.com/documentation/swiftui/view/accessibilityactivationpoint(_:)-9l0w0
The observed native glass hierarchy includes a zero-sized intermediary while the
semantic frame and working coordinate center are finite. Descendant-derived
activation is therefore a hypothesis to test; it is not yet an established cause.
This changes accessibility gesture targeting, not drawing, physical hit shape,
animation, haptics or route/admission. Preserve both AX and route assertions.

The explicit-center candidate `c096fc5`, native run `39651444663`, also finishes
**RED** after real generation/build: the same two AX failures; coordinate route
true. Artifact `12370816515`, digest
`sha256:2d7bc5bc419f41e66e3d50fe16e54b2548f2f5a6955157379c9c4214289815f2`.
Remove the ineffective activation-point settings. A bad default point alone does
not explain the failure.

The third controlled candidate hides only the styled label's accessibility
subtree, leaving the outer Button's explicit name/identifier/action and the
native glass's ordinary interaction intact. This tests whether the label's
native-glass AX descendants obscure the semantic Button. It changes no drawing,
layout, hit shape, spring, disabled/admission condition or feedback. The existing
existence, AX hittability and actual route assertions must all remain; if SwiftUI
also hides the Button or the obstruction persists, this candidate must be removed.

### Third control and restored UI boundary

Label AX omission `62b7207`, native run `39654790096`, generated/built and ran
one UI case with the same **two AX failures**. Unique Settings Button and spoken
name assertions passed; frame remains `(34,784,56,56)` and coordinate route true.
Thus hiding the label subtree did not solve the semantic hit failure. Artifact
`12370993959`, digest
`sha256:f5289dc14d0cf45828a523edb0360e5ddef0b301776fd854425aef4e6a996358`.

All three ineffective modifiers and the temporary product hit/callback probes
are now removed. `App/`, `Config/`, `Resources/`, and `project.yml` are restored
byte-for-byte to frozen product `eb39a65`. Unique-ID/spoken-name regression checks
and all earlier assertions/evidence remain. The known RED is not rerun unchanged
or waived, and PR #37 remains unmerged; S6 has not started.

Read-only history shows main already used native interactive glass inside the
Settings label, but used `.plain` rather than the custom pressed scale/spring.
The outer Rail mask also changed from a straight reveal to rounded subtraction.
Neither difference is a proven cause. Further decisive omission controls would
temporarily affect the frozen press animation or reveal clipping, so they need
the owner's new direction before implementation. The concrete proposal is
[the diagnostic plan](../Docs/superpowers/plans/2026-10-22-sidebar-ax-controls.md).
# 2026-10-22 authorized independent Sidebar composition controls

Owner requested another attempt after the concrete style/mask diagnostic proposal. Three independent launches retain all original semantic identity, AX hit, frame, and coordinate-route assertions: baseline; Settings-only plain ButtonStyle; Rail-only mask omission. Neither omission is a proposed final UI. Default control must reproduce the AX failure for causal interpretation. Source is restored after evidence before any final integration gate. Local syntax, YAML and 12 CI-script checks pass; native result is pending.


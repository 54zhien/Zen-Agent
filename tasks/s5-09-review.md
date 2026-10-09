# S5-09 review and repair ledger

Status: in progress on draft PR #26, stacked on unmerged PR #25. This record is
not a Stage 5 closure or physical-device acceptance. The owner will review the
whole stage before the device pass.

## Verified checkpoints

- Model/container checkpoint `ec7e8f5`, tree
  `f0bd5edc57c36184f3148270c4625c7dd8a05cc7`: CI
  [36671824961](https://github.com/54zhien/Zen-Agent/actions/runs/36671824961)
  passed XcodeGen, build, 824 Swift Testing tests, 20 XCTest tests and the UI suite.
- Either-Pane Lift / selecting the already occupied Pane regressions at `266ec81`,
  tree `5821e00de978eb193c397a98011199f9caf661a9`: CI
  [36673475262](https://github.com/54zhien/Zen-Agent/actions/runs/36673475262)
  compiled and failed the intended behavior assertions. The existing Split UI
  paths and 20 XCTest tests passed.
- Initial correction `92c0e46`, tree
  `97dcbe61197ae0435f894f3730afb5029a111dd1`: CI
  [36675744955](https://github.com/54zhien/Zen-Agent/actions/runs/36675744955)
  passed XcodeGen/build, 826 Swift Testing tests, 20 XCTest tests and all seven
  Split UI tests plus the existing UI suite. The build-settings guard also passed.
  Its local equivalent is `6d85adf`.

## Independent review findings

The review covered committed production through `6d85adf`; it did not treat the
new uncommitted regression tests as implemented fixes.

1. Pending/finalized deletion leaves stale Split ownership. Deleting the Lift
   origin also prevents Return to the already live other Pane.
2. Split Return first expands almost to Full, then shrinks into the original Pane.
3. The other Pane remains visible, interactive and accessible behind App Space.
4. Source Recent navigation discards Split; secondary navigation needs its own
   New/Recent actions and replacement path.
5. Native Composer focus does not update active Pane.
6. The card menu has no Open in Split action.
7. Empty Picker cannot access history beyond its first bounded page.
8. Registration/residency failures need retryable Picker feedback.
9. Divider must share the Pane geometry's safe-area midpoint.

The suspected permanent `.split` state after a gesture drop was withdrawn:
native viewport invalidation restores `.full`, and the existing UI test types
into the source editor after the actual drag/drop.

## Repair ownership

- App shell owns Conversation/Pane/bridge registrations, navigation tickets and
  deletion reconciliation. Pending deletion detaches the affected live Pane but
  preserves Undo data. Successful Return after a deletion collapses the suspended
  arrangement to the selected surviving Single; Undo does not recreate a Split.
- Workspace owns two stable physical Surface hosts and a small observable
  presentation-owner mapping. A lifted secondary Surface must survive collapse
  to Single; the unused host renders no second editor. Controller/host bindings
  remain fixed through the handoff.
- Lift owns geometry and a tokenized late handoff. Install the handoff before
  model/frame mutations and complete it exactly once, including the case where
  the expanded Card viewport is already the final Single viewport.
- An already live survivor transfers its existing Pane/bridge and router
  registration. Preparation cancellation must not unregister that borrowed owner.
- Composer reports actual user focus to Workspace; Runtime events never select a
  Pane. Only the inactive Composer receives slight visual de-emphasis.

### Handoff details checked against existing code

`ConversationSurfaceHost` installs its SwiftUI root once. The physical-host owner
mapping therefore must be an observable reference read inside each hosted root;
passing a newly computed Boolean to the representable would leave the installed
root stale. Each host retains its own Lift controller. The source/secondary
semantic role can change without rebinding that controller to another host.

For Return, capture the current visible rectangle in window coordinates, arm a
one-shot handoff token, then commit the prepared owner and change the viewport.
Viewport notifications during the mutation must not invalidate the committed
transition. An after-layout fallback consumes the same token if no size change
occurs. Rebase the captured rectangle into the final host and settle to Full.
The first segment must already move toward the actual Pane destination; expanding
toward a full-screen resting pose and then rebasing would preserve continuity but
still take the wrong route.

When a deleted origin's selected destination is the already live other Pane, use
the existing Pane/bridge as the prepared owner. Mark that preparation as borrowed
so cancellation cannot unregister its live routing or cancel unrelated maintenance
preparation. Successful collapse promotes its existing Session with single-owner
activation. The router's current unregister-then-prepare sequence is unsuitable:
unregistering also cancels the preparation ticket and marks the route dirty.

Pending deletion must not use `rememberSession` as its retention operation: that
helper intentionally removes Sessions whose durable row is no longer visible.
Retain the affected Session explicitly with unavailable reconstruction until Undo
or finalization resolves it, then detach its Pane/router registration. A Return
must not pass that deleted ID to the two-owner activation precondition.

The navigation changes must preserve the outgoing Pane until the replacement has
loaded and registered, invalidate stale selections, retain its draft/Run state,
then replace only its slot. A source-side Recent selection of the already occupied
secondary selects that owner; an empty Picker continues excluding the source ID.

The card-menu Open in Split path should prepare its selected card through the
same Return owner, with an explicit Pane destination and an empty opposite Picker.
The command must wait for native menu dismissal before starting Return. Existing
Split uses its established Return/replacement semantics; no third Pane is created.

The next test-only tree is `87734c76c6a5a7843545561f81257539ae8cc20b`
(`5c96305` remote object; local `c3b8873`). It adds deletion/Return, focus, Pane
navigation, continuing dual Runs, direct Return geometry, hidden sibling
accessibility, card-menu entry, and editable Single after secondary-host collapse.
Published after the preceding CI passed. Push CI compiled and then failed the
intended deletion, native focus, secondary/source navigation, direct Return,
hidden sibling and menu/collapse behavior assertions. Swift Testing ran 833 tests
in 123 suites with 23 issues; 20 XCTest tests passed. UI ran 30 tests with seven
failures: six assertions in the expected Split regressions and an additional
existing Chinese input test (`ComposerMotionUITests`, received only “你”). The
latter is tracked separately and must pass the final suite. No test-host restart
was reported. Production correction started only after inspecting this log.
The independent PR run reproduced the same 23 Swift issues and six Split UI
assertions; its existing Chinese-input UI test passed. This is an intermittent
failure observation, not evidence that the input issue has been fixed.
PR CI is [36677615987](https://github.com/54zhien/Zen-Agent/actions/runs/36677615987);
push CI is [36677465965](https://github.com/54zhien/Zen-Agent/actions/runs/36677465965).

## Remaining gates

### Current repair candidate

The repair commit is `86222c42b92ae00fad7bc6e36461d70237707c68`, exact tree
`546da8245c5bf8894775bc4079090ed6e0744162` (local `c2f5a54`). Its child
`b6f5f9e54b3d1a7cf0dcb793ac756d47e56dcb4e`, tree
`91eb58f9e9fab863d6909def3099c2ee78a79d55` (local `c24b037`), adds a new
native Browse transport regression. The old host's late viewport write and
unbind must not steal the new host's callback or stop its gesture. Production
transport ownership is intentionally unchanged until that test's compiled RED.

Candidate [push CI 36680216019](https://github.com/54zhien/Zen-Agent/actions/runs/36680216019)
and [PR CI 36680221545](https://github.com/54zhien/Zen-Agent/actions/runs/36680221545)
both passed generation/build, then reproduced 7 issues across 834 Swift tests
and 3 failures across 30 UI tests; all 20 XCTest unit tests passed. Five Swift
issues came from older test helpers selecting the first of the two stable hosts
instead of the Current Card. The two new transport assertions reproduced the
stale viewport/callback defect. UI exposed the hidden sibling's editor and an
uneditable surviving Single after deleting the opposite Pane. These are not
accepted results. Guard self-test passed.

The next candidate fixes transport ownership and native container visibility,
selects Current Card explicitly in the existing tests, and adds a Full-phase
assertion before the surviving Single's unchanged real typing assertion. It also
adds the failed Split preparation regression; its production correction awaits
a compiled failure from that test.

Independent review of this candidate confirmed the fixed-host mapping and the
handoff ordering, with no further concrete deletion/borrowed-owner defect. It
confirmed the transport regression and found a second boundary: failed menu
Split preparation leaves a destination intent that a later ordinary Return can
consume. A focused native regression is being added before correcting that path.
The source Return handoff marker is also being moved before observable Pane/ID
mutations; no deterministic animation failure from the former ordering has been
established.

Candidate `2cc9548864b15d7beca1ffb03695b49bcb6a76aa`, tree
`66115542bb06aa17c93a6cdc109e00baa0c3ba17` (local `0581d87`), passed
generation/build in [push CI 36683032202](https://github.com/54zhien/Zen-Agent/actions/runs/36683032202).
All previous Swift failures passed; the new failed-preparation regression was
the sole issue across 835 Swift tests: a later ordinary Return consumed `.top`
instead of no Split destination. All 20 XCTest unit tests passed. All three
Split UI failures persisted across the 30 UI tests. The new secondary Full-phase
assertion passed before typing failed, so a stuck Return phase is not supported
by this result. Native root visibility alone did not fix hidden-editor exposure.

The next candidate clears the entire failed Return operation through the existing
cancellation boundary and adds DEBUG-only live native interaction diagnostics to
the failing UI paths. It also adds a separate regression for reclaiming Browse
on a retained host before the departing host unbinds; the same-controller fast
path currently skips ownership validation. That production correction awaits
the new regression's compiled RED. Resize test drafts are separate, unpublished
S5-10 work and are not part of this candidate.

Candidate `259d6f61a0197de3c33107af39708a15cf436e49`, tree
`faaa80c055687122ebab98f37fa2be6cd3cc093e` (local `c0676e6`), passed
generation/build in [push CI 36685026441](https://github.com/54zhien/Zen-Agent/actions/runs/36685026441).
The failed-preparation regression passed. The new same-controller Browse reclaim
test produced all three remaining issues across 836 Swift tests: owner, viewport
and callback were stale. All 20 XCTest tests passed. UI ran 30 tests with five
failures: the three existing Split failures plus distant Browse failing its first
swipe and configuration-sheet draft typing failing its final value assertion.
Those two additional failures remain tracked; neither is waived.
The independent [PR CI 36685034448](https://github.com/54zhien/Zen-Agent/actions/runs/36685034448)
reproduced the three Browse unit issues and three Split UI failures, while its
distant Browse and configuration-sheet draft tests passed.

Live native diagnostics identify the Split UI boundaries. The surviving Full
editor is interactive, but its center hits the deletion banner's outer
`HostingScrollView`, not the Composer. The hidden sibling has correct native
hidden/interaction/accessibility flags and a zero-alpha ancestor, yet its nested
SwiftUI accessibility tree still exposes an editor. There is no evidence that
SwiftUI overwrites the native visibility flags.

The next correction validates Browse ownership before taking its same-controller
fast path, suppresses accessibility inside the retained hosted SwiftUI root, and
places Full deletion notices in the active Pane above its measured Composer.
Card notices retain their existing position; the ten-second Undo state and actions
are unchanged. The real typing regression additionally checks that Undo remains
available above the editor. The configuration-sheet test now logs its actual
draft on failure without changing its assertion.

- Observe compiled behavioral RED for the repair tests, then implement and run
  full macOS generation/build/tests.
- Re-review native host lifetime, stale async work, duplicate owners and menu/
  Picker paths; record the exact accepted tree and CI.
- S5-10 owns ratio/resize/close thresholds and continuous bottom-anchor behavior;
  S5-11 owns rotation and iPad axes.
- Physical animation comfort, VoiceOver usability and performance remain open.

## Retained hidden content and release samples

Candidate `6142ee5a444af53ba42b086e7e9f0afeb0793e61` (local `7e423d1`,
tree `aa06092880ce073100346352fd3652d837c7551f`) passed generation/build,
836 Swift tests and 20 XCTest tests in both CI runs. PR CI 36687762409 ran
30 UI tests with the two hidden sibling editor failures; push CI 36687756359
also failed distant Browse at history 5. Full Undo placement and surviving
Single editor typing passed in both runs. Inner SwiftUI accessibilityHidden
therefore did not solve the hidden native editor exposure.

The next candidate detaches only the hidden hosting UIView, retaining its child
controller, root, native editor, Pane and Session. It reuses the same constraints
on return and suppresses off-window safe-area and Timeline geometry updates.
The viewport observation includes visibility, so an identical-size remount can
resume pending reading work. Native lifetime coverage checks window membership,
editor identity/selection, draft, Run state and safe area across repeated hides.

A new native Browse test supplies an ended displacement beyond the threshold
without an intermediate changed sample. Production currently consumes only the
release velocity; this test must produce compiled RED before that correction.
Bounded DEBUG gesture/viewport logs accompany the intermittent Browse UI path.
S5-10 drafts remain unpublished and excluded from this candidate.

Source review of local `12cfaaf` found a remaining ordering risk: visibility alone
can allow a pending scroll request to be acknowledged from the retained old
viewport before the first remount measurement arrives. The follow-up uses a
visibility revision and a Timeline-local accepted revision. Geometry and scroll
requests remain gated until usable geometry for that exact attachment arrives.
Review found no further concrete production blocker in that correction.
The native UI regression now queues an anchor while hidden, reduces the fixture
viewport height, and checks placement in the new viewport on Return; this avoids
an equal-size round trip masking use of stale geometry. CI evidence is pending.

Candidate `da4c61954a14a277c739257529d59cb9340e0062`, exact tree
`ec3f49bf5f76b911885e26ca0ec3fe419241a866` (local `12cfaaf`), passed
XcodeGen/build in CI 36690767767. Native hide/remount identity tests passed;
837 Swift tests had only the expected final-release issue (Current instead of
Older). All 20 XCTest tests passed. Both hidden-editor UI regressions, including
the sibling reading-position check, passed. Across 30 UI tests, one test produced
two failures because Undo was absent. The timestamped trace shows SpringBoard's
`NotificationShortLookView` interrupted Return for about seven seconds; Undo was
queried more than ten seconds after deletion. No test-host restart was detected.

The next candidate consumes final Browse displacement before velocity settlement
and covers both crossing the threshold at release and returning below it. The
Undo layout/typing test now dismisses that specific system banner through an
XCTest interruption monitor, retaining the real ten-second production deadline
and all existing Undo/typing assertions. The already reviewed current-attachment
geometry correction joins this candidate; its changed-viewport UI check remains
pending. S5-09 is not yet accepted.

### 2026-10-04 exact-tree repair verification

Candidate `71e76de7e99c2c8f156b42b0616e658c39169b7c` / tree
`535c59cddd73ab995bfc99c3b19be46e81aa5ef6` passed generation/build,
837 Swift Testing tests in 124 suites and 20 XCTest unit tests in both
push CI 37137948804 and PR CI 37137951724. Both 30-test UI runs had one
failure in the strengthened hidden-reading test before its new viewport
roundtrip: the all-element Pane query matched both a ScrollView and an Other
because SwiftUI propagates the identifier. The remaining 29 UI tests passed,
including Browse and editable Single with the real Undo timeout. No test-host
restart was reported.

The query now explicitly measures the native timeline ScrollView, preserving
all queued-request, viewport-height and actual Turn-position assertions. Source
behavior is unchanged; the changed-viewport portion still needs successful CI.
Independent read-only review of `12cfaaf..7606d83` found no concrete blocker
and confirmed the release crossing/retreat regression and current-revision
geometry gate. Subsequent slice drafts remain unpublished.

## Final S5-09 candidate — 2026-10-04

Remote `08e950abf55d895f502fec2139262343275783f4`, exact tree
`1d66027b2b4875245ffc492e011f6128798c3ab0` (local `95b854e`).
37139550698 passed XcodeGen/build, 837 Swift Testing, 20 XCTest and all
30 UI tests. The strengthened changed-viewport restoration passed. Final
read-only cumulative review found no concrete remaining blocker.

Parallel PR 37139554202 passed build/units and that new regression, but
an older Browse UI test's initial Lift never entered Card. This intermittent
admission failure remains explicit, rather than being called a second GREEN.
Draft PR #26 remains unmerged; physical-device gates remain open.

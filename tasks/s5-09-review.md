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

- Observe compiled behavioral RED for the repair tests, then implement and run
  full macOS generation/build/tests.
- Re-review native host lifetime, stale async work, duplicate owners and menu/
  Picker paths; record the exact accepted tree and CI.
- S5-10 owns ratio/resize/close thresholds and continuous bottom-anchor behavior;
  S5-11 owns rotation and iPad axes.
- Physical animation comfort, VoiceOver usability and performance remain open.

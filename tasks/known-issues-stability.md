# Known issues stability repair — 2026-10-11

The owner requested investigation of current known issues, serial root-cause
repairs, then a whole-project review and native stability/functionality checks.
This is a new authorization; historical deferrals remain evidence, not closure.

## Ownership and baseline

- Own worktree: `C:/Users/Azusa/.codex/worktrees/known-issues-stability/Zen-Agent`.
- Own branch: `codex/known-issues-stability`.
- Starting HEAD: `c99328641d3227c6ecd1435dc461e4ae02759704`.
- S6-02 source baseline: `bac8a66e495302ecc0134069f1a0c58558ee5542`.
- Main observed at start: `52a456bb53d10360aa6d485202f4bd05e2c6bdbf`.
- Blueprint intent: recorded approved `3b4b22c0df91be668406127c84c1822b359883c0`.
- Other worktrees, original diagnostic/S6 branches and main are not edit targets.
- No later Stage features, tool enablement, merge or IPA is needed for this repair.

## Issue register and serial execution

1. Diagnostic loss at Composer detach/configuration removal. Root boundary:
   `ComposerLiftInteraction.gestureChanged` exits before recording a terminal
   event if configuration/window is absent; host-local history can disappear.
   First prove the loss using the actual handler and driver with native views,
   then repair DEBUG record ownership without changing gesture behavior.
2. Settings first Lift cancellation. Original run `37939650854` proves native
   admission/arming followed by cancellation. No source of cancellation is yet
   proven. Inspect archived session data and original native owner lifecycle,
   then add one discriminating observation/test before any behavior change.
3. Native Sidebar first opening, including current run `38107934110` failing
   before Settings and historical iPad failures. Determine whether admission,
   arbitration, delivery or lifecycle fails; retain one-drag assertions.
4. Dock settled incoming focus loss. Preserve cold `37784846258` and clean
   `37801912044` failures. Keyboard-arbiter resignation is observed; connection
   timeout source remains unknown. No unconditional refocus, waits or retry fix.
5. SQLite fixture ownership: current S6-02 native log still reports three
   `formal-configure.sqlite` vnode-unlinked warnings. Trace retained store owners,
   assert their release before deletion, then repair the responsible lifetime.
6. S6-02 corrupt/future-intent cold-reopen coverage. Extend real disk recovery
   across pending states, asserting original ID/JSON, durable rejection and zero
   executor entry. A passing characterization is coverage, not a new bug repair.
7. Policy aggregate equality uses Swift text equivalence for opaque identity
   fields. Determine real consumers and intended equality; cover byte-distinct
   values before any correction. Existing evaluator compares identities by bytes.
8. Final audit: reconcile stale status records, inspect existing modules and
   inherited review suggestions, and add any concrete defects to this register.
9. Rename prefill: `AppSpaceConversationActions.title` still returns an empty
   stored title while the Card displays the first-message provisional title.
   Preserve full manual titles and reuse the bounded summary for the fallback.
10. A stale bridge focus snapshot can undo a newer native Dock transfer. This is
    distinct from the historical delayed keyboard-arbiter resignation in Issue 4.
11. Split selection sends `textAreaTapped` to an incoming Compact Composer. The
    reducer only accepts that event from Resting; Compact needs `compactTapped`.
    Prove the model's focus intent before UIKit can accidentally rescue it.

## Evidence

- Issue 1 behavioral RED: `b5f5e2ba2e2e75afc17292b37e03b3da6e8c4802`,
  run `38110707869`, Phone job `114385526389`. XcodeGen and app/test compilation
  succeeded; the three native handler cases produced seven expected assertions:
  missing began/terminal evidence on all original drivers and misattribution to
  the replacement driver. One Swift test-run start. This proves recorder lifetime,
  not the initiating cause of the historical OS gesture cancellation.
- Issue 1 candidate keeps bounded DEBUG evidence on the weak original driver
  and records terminal callbacks before the native attachment/configuration guard.
  The production recognizer and Lift transitions are unchanged. Native GREEN pending.
  The RED receipt also exposed an inferred `SQL(elements: [])` peer join;
  explicitly require a String so an empty peer list is recorded as `peers=[]`.
- Issue 5 source hypothesis: Runtime callbacks strongly capture Router, which
  owns Pane, Session and the cached Send coordinator/bridge back to Runtime.
  Existing idle-shell release coverage never creates that coordinator. A release
  regression must confirm the cycle before changing ownership.
- The next native invocation also introduces Issue 5 test-only cases: idle shell,
  cached coordinator, completed Send, and an active Runtime outliving presentation.
  Recorder GREEN and ownership RED are assessed by their individual suite results;
  no whole-workflow GREEN is inferred from a partially passing diagnostic run.
- Next test-only preparations cover Issues 6, 7 and 9: corrupt/future intent
  disk reopen (including an actual waiting-for-approval Run), byte-distinct
  aggregate Policy identity, and provisional/empty/full-manual/deleted Rename
  prefill. These are not executed until explicitly selected by a native run.
  The Settings failure message also captures the post-drag Sidebar probe; the
  old receipt contained only the pre-drag value. No gesture, wait or retry changes.
- Issue 1 native GREEN: `bdc7c7526362a5e1d0f1dbe94e36cd80c87a9bf0`,
  run `38111570030`, Phone job `114388075687`: all three handler boundaries passed,
  including correct empty-peer String output. The workflow is RED for Issue 5.
- Issue 5 behavioral RED on that same head/run: idle control released; cached
  coordinator and completed Send each retained Router/Pane/Runtime/database;
  a separately retained active Runtime retained Router/Pane after shell release.
  Ten expected assertions failed; active execution itself still completed.
  The original `formal-configure.sqlite` vnode warnings also reproduced.
- Issue 5 candidate weakly captures the presentation Router in both Runtime
  callbacks. Dependencies/AppShell still own Router, and Runtime retains its own
  active operations and persistence acknowledgement. No fixture delay/cleanup
  suppression is used. Native release, active completion and warning checks pending.

## Verification and review

`4e8f58729cdfd390bdfb37edaed5c61c3521290a`, run `38112323592`, Phone job
`114390295830`, built successfully and ran 1,070 Swift tests in 167 suites plus
20 XCTest unit tests and the four original Settings predecessors. There was one
Swift run start and no host restart. The expected total of 25 assertions failed:

- Issue 5 GREEN: all shell release and active Runtime persistence cases passed;
  `formal-configure.sqlite` vnode-unlinked warnings no longer appeared. Persisted
  empty Configure also passed. This closes the reproduced ownership defect.
- Issue 6: legacy and corrupt/future real disk reopen cases all passed, including
  actual waiting-for-approval Runs. This adds coverage; no source repair was needed.
- Issue 7 RED: aggregate identity equality produced 23 assertions merging
  byte-distinct Unicode identities. Explicit byte equality now covers all raw
  identity fields and preserves every other member comparison. Intent validation
  reuses the corrected metadata equality instead of a duplicate comparison.
- Issue 9 RED: provisional and empty title prefill failed; full manual and deleted
  controls passed. Source repair waits for Issue 7 GREEN.
- The original Dock focus function and all four selected Settings UI cases passed.
  They do not establish a root cause for Issues 2–4. iPad job `114390295783` passed
  its actual native axis case in 115.722 seconds.

The next diagnostic selects Policy/intent regression suites plus ownership,
receipt and Rename cases. It intentionally still exposes Issue 9; final full
selection will be restored after the serial fixes.

`1530c3837a500e323da9c14fe86fb2aa6969e750`, run `38113326705`, Phone job
`114393241969`, compiled and ran 83 tests in nine suites (one Swift start; no
restart). All Policy equality/scope/evaluator/temporal tests and intent version/
continuation tests passed, as did shell lifetime and diagnostic receipt tests.
Only the two unchanged Rename assertions failed. Issue 7 is therefore GREEN.

Issue 9 now reads the existing bounded summary fallback only when the stored
title is blank under the summary's whitespace rules. A nonblank manual title
remains full length; a read does not rename anything. Coverage additionally
checks legacy whitespace-only titles. Native GREEN is required on the next head.

The temporary branch selector is removed: the next invocation uses the formal
full unit/Phone UI selection and the actual iPad job. Additional controls prove
that an active Runtime survives even without an external strong owner. The
original Dock focus test records scene/window/responder state and a bounded
stack only after unexpected B end-editing; its operations, timings and assertions
are unchanged. The Settings test retains the post-drag Sidebar receipt and Lift
retains its original-driver trace across transport teardown.

The owner reports Split switching losing input focus on an iPhone 15 Pro Max
and reports iOS 27.2. The exact operation chain, app build and system-version
confirmation remain unavailable. The observed CI uses Xcode 26.6 (17F113) and
an iPhone 17 Pro simulator on iOS 26.2; it is not a matching device-system receipt.
Issues 2–4 cannot be dismissed as simulator-only or closed by passing CI.

### Cross-module review scope

- App shell / Session / Router / Runtime ownership and asynchronous completion:
  the confirmed cycle is repaired; active execution keeps its durable projection.
- Frozen intent preparation, pending rejection CAS, provider continuation and
  disk recovery: original call/attempt/JSON are preserved; rejected or historical
  results do not authorize execution. Full Policy integration remains S6-04 work.
- HTTP/Provider cancellation and failure paths: existing bounded stream/error
  processing and no automatic POST replay remain intact.
- Files import/removal and presentations: worker draining, publication/removal
  locking, draft reservations and protected presentation copies remain intact.
- Settings configuration, account credentials and Soul: captured-session identity,
  revision checks and persistence publication own updates, not a closing view.
- App Space metadata and navigation: Rename fallback is corrected; the three
  native input stability questions above remain open and block an all-fixed claim.

The subsequent focus investigation confirmed Issue 10 below. This is a review of
the candidate diff and high-risk module boundaries, supported by the native
regression suite; it is not proof of every possible device behavior.

### Bridge focus snapshot regression

Test-only `6c83fdb3c60ee57714fbe25e7b6e2116ee84f41d` ran independently on
`codex/known-issues-focus-diagnostic` so the full `b893487` run was not cancelled.
Run `38114488287`, Phone job `114396586140`, compiled and ran 99 tests in two
suites with one Swift start. Exactly three assertions failed in the stale-blur
case: immediate native focus, controller Editing, and settled native focus.
The explicit new blur control passed. The strengthened real AppShell test also
passed its actual focus and IME guard assertions; this alone does not reproduce
the owner's physical-device incident.

The old bridge captured a Bool while the incoming controller was resting.
Native Dock handoff then synchronously published Editing, but a pending bridge
update replayed that old false value and called `resignFirstResponder`, whose
delegate overwrote the controller back to Resting. The candidate passes a live
focus projection of the existing controller through the bridge and reads it at
the application boundary, including after Dock registration callbacks. There is
no second focus owner, timer, forced-refocus loop or delay. The regression's API
arguments now supply that projection; operations and assertions are retained.
An explicit blur before any focused bridge refresh must still apply.

The end-to-end Split test previously tapped the incoming editor again before
typing, masking a possible handoff failure. It now requires native focus and
keyboard continuity without that extra tap, in both switch directions. The next
diagnostic includes it and the existing Composer/IME/layout regressions. The
temporary branch-only selector must be removed before the final full gate.

Issue 10 native GREEN: `848d85208160bded66be21a143de617dcd49bc30`, run
`38115219514`, Phone job `114398690346`. All 122 tests in six suites passed in
26.701 seconds, including both stale-render/new-blur arguments and the original
focus regression. The actual Split UI test passed in 52.250 seconds without the
extra editor tap. There was one Swift start, no host restart and TEST SUCCEEDED.
This must not be used to close Issues 2–4.
The preceding full head's actual iPad case passed in 86.511 seconds (job
`114395487417`); its full Phone gate is still running at this record update.

The next test-only change adds Resting/Compact arguments to the real shell
focus regression and checks the target's Editing intent immediately after
selection, before UIKit handoff. The Compact precondition is established and
required immediately before selection so layout cannot silently turn the
fixture back into Resting. The production selection code is unchanged for RED.

- [ ] Record each confirmed root, RED SHA/run/assertion and minimal repair.
- [ ] Obtain GREEN on the same behavioral regression before the next repair.
- [ ] Restore the formal full CI selection after temporary diagnostics.
- [ ] Review the full candidate and current architecture: ownership, persistence,
  cancellation, recovery, provider/tool boundaries, UI input and navigation.
- [ ] Run static hygiene/profile checks, XcodeGen, build, all unit/Phone UI tests
  and the actual iPad job on the final exact HEAD. Inspect executed counts and
  host restart evidence, not only workflow badges.
- [ ] Report outstanding device-only acceptance separately. A new passing run
  does not erase an unexplained earlier failure or prove all environments stable.

Windows has no native Swift/Xcode toolchain. Compilation failures are not
behavioral RED. Interrupted/skipped workflows are not GREEN. Native diagnostics
must answer a new question; unchanged retries are not repairs. Final exact-HEAD
receipts live outside the checkout to avoid self-referential SHA commits.

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

## Verification and review

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

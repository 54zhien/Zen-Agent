# Known issues stability repair — 2026-10-11

## Current scope: device glass and motion — 2026-10-15

The owner requested stronger natural Gaussian glass at the top, a fade behind
the Composer, larger safe-area-aware Sidebar controls, smoother Sidebar motion,
glass enlargement and one soft haptic on long-press readiness, free two-axis
card transport, screen-matched floating corners, progressive Sidebar/card
opacity, a lighter outlined Dark card, and larger Composer symbols without
black button fills. The upstream intent is recorded on Blueprint branch
`codex/device-glass-motion-20261015` at `51b4dc33beec515c7d684d352060fbdeded1825e`;
neither repository has been merged to main for this slice.

The product/test source before temporary touch diagnostics is `88f65eb849d7`.
Its packaging candidate `421813b841da` built successfully, passed 1,120 Swift
tests, 20 app XCTest cases and the actual iPad case. Its original full run
`38707241764` remains RED: 78 Phone cases passed, one Settings case failed, and
the iPad-only Phone skip ran separately on iPad. Later artifact-cleanup timeout
does not turn the native failure into a passing or infrastructure-only run.

The earliest Settings failure preceded opening Settings: the first blank tap
had no Timeline SpatialTap completion and did not dismiss the keyboard. Later
Lift rejection correctly retained the keyboard eligibility guard. Read-only
archive decode run `38724778838` inspected the saved original xcresult, without
executing its app or tests again. At 09:11:52 UTC, XCTest synthesized down/up at
`(394,387)`. BackBoard initialized two touch states for sender `102F270F000AD`,
skipped seven events for its path 2, then cancelled that still-touching path
when the virtual digitizer disappeared. Successful adjacent touches had one
state and no remaining contact at removal. These are direct upstream input
lifecycle anomalies and cancellation evidence. They do not expose the App's
UITouch phase/hit view or establish whether a system edge gesture contributed.
Do not infer a Settings, focus or Timeline repair from this failure.

The owner confirmed that the same first blank tap dismisses the keyboard on
their phone. Diagnostic runs `38716159968` and `38718872777` passed the original
Settings case and then its complete seven-case class. The original UI-prefix
diagnostic run `38722347334` passed all 24 original prefix cases, 1,120 Swift
tests, 20 app tests and the actual iPad case without a host restart. The first
blank tap completed and dismissed the keyboard. These are diagnostic receipts,
not product repairs or replacements for the retained full RED.

Temporary profiles, workflow selection and touch observers were removed from
clean source `56377f925434`. Its workflow-only packaging candidate `de1c2cefb201`
passed original full run `38726272805`: 1,120 Swift tests, 20 app XCTest cases,
79 Phone UI cases and the actual iPad case, with only the expected iPad-only
Phone skip and no test-host restart. IPA 8.1 was built and provenance-verified,
but withheld after final screenshot review found a separate visual defect.

The idle Full native receipt reports a 402x874 Surface and a Composer host at
window `(0,62,402,778)`. The fade ended at y840, leaving the 34-point home safe
area uncovered; the scrolling screenshot still exposes text there. This is an
actual viewport-boundary defect. Test-only source `bedf1d4a5a8b` adds light/dark
Full and upper/lower Split rendered-pixel regressions before changing production
behavior. Its native run `38735814351` is preserved separately from the earlier
input failure: 1,121 Swift tests ran once, with 18 issues confined to the new
fixture; 20 app tests passed. The unchanged Full light/dark pixel assertions
failed and their resting endpoints were each exactly 34 points short. Initial
isolated Split fixtures and the unbound floating fixture were not faithful to
production: Split uses the shared dock, and transformed keyboard conversion
requires the real Lift binding. Those controls are replaced with the actual
Portal/dock install/embed route for both logical owners and the bound Full
Surface. The strict Full pixel/endpoint assertions remain unchanged. Shared-dock
input remains at the Workspace bottom even when the
upper Pane owns its draft, so its visual viewport must not use that logical
Pane's bottom edge.

The minimal repair chooses the nearest actual Surface bounds for embedded
input, extending its existing sublayer through the card's home area. Shared-dock
input uses the root viewport's converted vertical extent and keeps its local
horizontal extent, so Sidebar translation is not cancelled. The existing
keyboard-top limit, parent crop mask and reparent/layout callbacks remain the
owners of clipping and movement. No focus behavior, timing or retry is added.
Native GREEN and a new exact-candidate full gate remain required before delivery.

Final exact-candidate receipts live outside the checkout to avoid committing
self-referential SHAs. Physical frame rate and haptic feel remain device
acceptance, separate from simulator animation and lifecycle tests.

## Historical continuation: native message-body focus

The owner authorized continuation from the 2026-10-11 handoff, including an
unsigned device IPA after repair verification. The active repair branch is
`codex/fix-split-content-focus`, based on production candidate `f72e653` through
the existing body-tap diagnostic `b775fa7`. Historical pending entries below are
chronological receipts, not current passing claims.

Two compiled native UI REDs (`db2ea475`, run `38124430504`, and `b775fa7`, run
`38125268566`) reproduce the same real message-body tap losing the Composer
responder. The unchanged margin tap passes. The original application stdout
was exported from artifact `11697760988` by evidence-only run `38127305191`:

1. `SPLIT_CONTENT_SELECT` still sees outgoing Editing and incoming Resting.
2. The incoming Dock editor becomes first responder; the outgoing editor's
   didEndEditing stack is the expected `ComposerDockContainer.install` transfer.
3. `UITextNonEditableInteraction.oneFingerTapInUneditable` then acquires a
   responder for the message body and resigns the newly installed Composer.

This disproves the earlier hypothesis of outgoing focus loss preceding Pane
selection. The first candidate attempted the read-only Quote text view's public
`UIView.gestureRecognizerShouldBegin` admission hook. It did not prevent the
original native focus loss, so that behavioral veto was removed. Observation
commit `4909599`, run `38128821010`, confirms zero calls to that view hook. At
body responder acquisition, the single tap is an attached public
UITapGestureRecognizer in ended state with one tap and one touch; at long-press
acquisition, tap recognizers are still possible and the loupe gesture has begun.
This supports a second candidate at `becomeFirstResponder`: decline an inactive,
read-only body's recognized single-tap acquisition. Prompt presentation taps are
excluded by object identity. Long/double taps and non-touch acquisition continue
to UIKit. No private class names/selectors, refocus, delay or retry are used.
AppShell/Dock transfer, IME guards and native blur retain their existing owners.

The initial candidate `656f4ed`, run `38127709745`, and diagnostic `4909599`
both built and passed 107 Swift tests in three suites, plus margin transfer and
explicit blank blur. Both retained the original body focus failure. Each had one
Swift run and no host restart. The long-press control's Copy failure was a test
locator defect: the captured accessibility tree exposes MenuItem Copy, while
the test queried Button Copy. Correct the query; selection was actually present,
but Quote drag was not reached. The new candidate also adds double-tap word
selection and non-touch responder/selection controls. Original body assertions
remain unchanged.

Candidate `9d16aaa`, run `38130144526`, passed the original body regression
(42.127 seconds), margin transfer, blank blur, and 108 Swift tests in four suites.
The run still failed added selection controls. Later `4e30ac4`, run
`38132893574`, again passed the original body case (41.540 seconds); it supplied
native menu/drag diagnostics rather than a full gate. Removing the focus veto
in control `7fe1f70`, run `38131845521`, restored the original body failure while
retaining the Copy/Quote failures. Those failures were not caused solely by the
body focus repair.

Menu dismissal has a separate recorded path: during keyboard hide, the viewport
grows while following-bottom emits new scroll commands. The native menu dismiss
stack enters through the SwiftUI hosting scroll view's content-offset update.
Control `6228027`, run `38133891725`, suppresses those app commands only for
diagnosis. UIKit itself clamps offset 1840.333 to the new bottom 1673, and the
active Prompt Copy control passes. The production repair skips a bottom command
when usable geometry already meets the existing target tolerance or lies beyond
the new bottom. It retains the request until actual geometry satisfies the
normal acknowledgement; anchor and maintained-bottom actions are unchanged.

The Quote failure was also traced: the old synthetic drag start engaged native
selection-range adjustment, never the text drag delegate. Starting inside the
selected word instead of near its handle passes in `6228027` (53.082 seconds),
with native item capture, host performDrop, Quote chip and original draft intact.
No production drag path was changed to obtain this result.

Run `38133891725` remains failed: Sidebar setup prevented the body-double test,
and an initial Composer keyboard connection failure prevented the original body
test before any message tap. Its didEnd stack is UIKit's remote-keyboard
failed-connection path; the underlying connection failure is not explained.
These are retained failures, not passing body controls or a simulator exemption.

Candidate `850d7e9`, run `38135417462`, passed all seven native UI cases with
zero failures in 405.348 seconds, including the original body case (81.386
seconds). Copy controls also require actual bottom geometry and no pending
request while the menu remains available. Application evidence records offset
1840.333 left pending, then native geometry at 1673 followed by the normal ACK;
the native menu presents afterward. This focused run intentionally excludes
the unit target and Pad, so it is not the full gate. Final exact-HEAD full receipts
are stored outside the checkout to avoid self-reference. Focused CI is not the
formal full gate; temporary observers and selectors are removed before freezing
the final source and preparing the separately authorized unsigned device IPA.

Settings first-Lift cancellation, the earlier first-Sidebar failures, and the
historical delayed focus loss remain separate unresolved evidence. Neither a
later passing diagnostic nor this different causal repair closes them.

## Device clarification: opposite content tap

The owner clarified the physical-device sequence: while the keyboard is open,
tap the other Conversation's content, then focus is lost. This narrows the
investigation to Pane selection, not axis switching or Split exit. The earlier
UI handoff regression taps a Timeline margin at x=0.97; the new diagnostic also
taps a visible seeded assistant message body, exercising native selectable text
before Pane activation. It preserves a margin-tap control, separate drafts,
keyboard and native focus assertions, with no second editor tap or retry.
This is a test-only hypothesis on top of f72e653, not another confirmed root.
The diagnostic branch temporarily selects Dock/Quote native tests and the two
handoff UI cases; Pad is intentionally skipped and the result is not a full gate.

Content-tap behavioral RED: db2ea4758f350565f54154cc304e2ce242a7c1e8,
run 38124430504, Phone job 114425762446. Fourteen tests in two native suites and
the unchanged margin UI handoff passed. The new UI case hit Assistant response
18 (a native TextView), recorded blank=false, switched to the source editor but
left it Resting and unfocused. Exactly one focus assertion failed after real
application/test compilation; no host restart. Next, fixture-gated DEBUG stack
and model-state observations establish whether native resignation precedes Pane
selection. They do not change recognition, responder requests or model events.

The owner requested investigation of current known issues, serial root-cause
repairs, then a whole-project review and native stability/functionality checks.
This is a new authorization; historical deferrals remain evidence, not closure.

## Initial ownership and baseline (historical)

- Own worktree: `C:/Users/Azusa/.codex/worktrees/known-issues-stability/Zen-Agent`.
- Own final branch: `codex/known-issues-stability-final`; the earlier
  `codex/known-issues-stability` full gate stays running on its original head.
- Starting HEAD: `c99328641d3227c6ecd1435dc461e4ae02759704`.
- S6-02 source baseline: `bac8a66e495302ecc0134069f1a0c58558ee5542`.
- Main observed at start: `52a456bb53d10360aa6d485202f4bd05e2c6bdbf`.
- Blueprint intent: recorded approved `3b4b22c0df91be668406127c84c1822b359883c0`.
- Other worktrees, original diagnostic/S6 branches and main are not edit targets.
- The initial slice excluded later Stage features, tool enablement, merge and IPA.
  The current continuation above additionally authorizes an unsigned device IPA
  after native repair verification; it does not authorize a merge or later Stage.

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
12. A window-wide keyboard hide can publish a false focus event while this host
    is configured Editing but has not yet acquired its requested native focus.
    Test both fresh and previously focused hosts through the real notification
    observer; genuine native resignation must still publish a false event.

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
The preceding full head `b8934878fa29a14a714847be59bc993a2181233f` completed
run `38114107871` successfully: 1,070 Swift tests in 167 suites, 20 XCTest unit
tests, and 61 Phone UI cases with the expected one Pad-only skip and zero failures.
Phone job `114395487376` had one Swift start, no host restart and no
`formal-configure.sqlite` vnode warnings. Rename and both active-Runtime lifetime
arguments passed. All seven Settings and ten Sidebar cases passed. The actual
iPad case passed in 86.511 seconds (job `114395487417`). This verifies the earlier
repairs including Issue 9, but does not explain the historical input failures.

The next test-only change adds Resting/Compact arguments to the real shell
focus regression and checks the target's Editing intent immediately after
selection, before UIKit handoff. The Compact precondition is established and
required immediately before selection so layout cannot silently turn the
fixture back into Resting. The production selection code is unchanged for RED.

In that test-only run `38115982163`, iPad job `114400875573` failed before test
compilation/execution: simctl reported a booted iPad, but Xcode listed only generic
destinations and could not resolve that UDID (exit 70). No native assertion ran;
this is unavailable acceptance evidence, not behavioral RED or GREEN. Preserve
the failure and require a real iPad result on the final repair head.

Issue 11 behavioral RED: test-only `d0e8c16a24036868aff4648a88f5f7de11d3b9ae`,
run `38115982163`, Phone job `114400875604`. Compilation succeeded and 122 tests
in six suites ran once. The Compact argument failed the immediate model-intent
assertion at AppShellWiringTests:228 (`.compact != .editing`), before UIKit could
repair it through its own focus callback. Its later native handoff assertions
passed. The candidate selects `compactTapped` for Compact and the existing
`textAreaTapped` for other states; IME/selection/Quote guards are unchanged.

This run also exposed four failures in the Resting control's settled native
focus/controller state, after a keyboard-queue timeout and XPC interruption.
That is separate unresolved evidence: the Compact event change cannot explain
it. Both arguments actually ran sequentially, so it was not cross-argument
window competition. An explicit serialized trait now preserves that requirement.
The shell test now records only an unexpected incoming end-editing callback,
with the same bounded stack/window observer used by the Dock regression. It adds
no focus request, warmup, timeout or retry. The shared Draft text is fixture-only
filtering to exclude the expected outgoing resignation. All five original
failure assertions remain. The stale-bridge regression and the real Split UI
test still passed (62.493 seconds) on the failing run.

The temporary diagnostic selector is removed; the workflow matches main's
formal full selection byte for byte. The next exact repair head must build and
run all unit/Phone UI tests and the actual iPad case. Do not close the unresolved
native loss merely because the Compact repair or a subsequent full run passes.

The first full repair head `57601a3cef1830fca1e8323bc7e2062740be1506`, run
`38117378404`, built the application but failed test compilation: the new
failure observer captured a non-Sendable Notification inside MainActor isolation.
This is not behavioral RED. The observer now extracts the MainActor-isolated
UITextView reference on its delivery executor before entering the isolated
callback. No operation, timing, source repair or assertion is changed. A new
full native result is still required.

The Issue 12 test-only diagnostic preserves the running full `b1146f0` gate on
the stability branch. Its new assertions exercise the real keyboard observer
before focus application, including a retained editor with prior native focus.
This is not yet a proven cause of the historical delayed arbiter resignation.
Production keyboard handling is unchanged for the initial RED invocation.

Issue 12 behavioral RED: `ff161a025344f15cbae9e22739b07076efa9a241`, run
`38118444246`, Phone job `114408035971`. The app and tests compiled; 130 tests
in seven suites ran once in 28.678 seconds, with exactly two failed assertions
at ComposerOverlayFocusTests:68. Both fresh and previously focused hosts received
the unexpected false event. Actual native focus acquisition and resignation
controls passed. The shell Resting/Compact handoff and model-intent assertions
passed, establishing Issue 11 GREEN; the real Split UI passed in 46.657 seconds.
The iPad job `114408035914` also passed its native case. No host restart occurred.

Issue 12 repair removes only the synthesized onFocus(false) from keyboard hide.
UITextView didEndEditing remains authoritative; keyboard transition bookkeeping
and native delegate handling are retained. Gating on prior keyboard ownership
alone would still lose the pending request of a previously focused editor, as
the second RED argument demonstrates. There is no focus retry or delay. The
workflow again matches main's full gate exactly; native GREEN is pending.
The preceding full `b1146f0` Pad job `114406525733` passed its actual case in
134.593 seconds. Its Phone gate continues independently and is not cancelled by
publishing the final repair branch.

- [ ] Record each confirmed root, RED SHA/run/assertion and minimal repair.
- [ ] Obtain GREEN on the same behavioral regression before the next repair.
- [x] Restore the formal full CI selection after temporary diagnostics.
- [x] Review the full candidate and current architecture: ownership, persistence,
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

# S5-10 Divider resize and closure

## Scope

Execute `Docs/superpowers/plans/2026-09-30-stage5-resize-orientation.md` Task 1.
Test-only baseline is local S5-09 `95b854e`, equivalent to remote `08e950ab` /
tree `1d66027b2b4875245ffc492e011f6128798c3ab0`.

## Current evidence

- S5-09 exact tree `1d66027b2b4875245ffc492e011f6128798c3ab0` passed
  37139550698: generation/build, 837 Swift, 20 XCTest, all 30 UI tests.
  Parallel PR 37139554202 passed the new changed-viewport test but had an
  intermittent initial Lift admission failure in an older Browse test.
- S5-10 test-only remote `dc82f24b0d2e20bfb28a836811c9d3d09a609dd4`,
  tree `1813e4dbb8735d1762fe9ad0ead6b915a26f91d2`, compiled in
  37139764904. Behavioral RED: saved anchor restored 400pt away because
  of the wrong Turn identity; Handle never resized, both explicit close
  actions were absent, and tapping the broad line closed Split.
- First production candidate adds Handle-only native pan/menu/adjustable
  actions, shared ratio geometry, tokenized per-Pane Divider leases,
  current-layout scroll receipts, source promotion with shared live content,
  and the corrected bottom reference identity. Additional tests check final
  receipt/token rejection, finite geometry, both active Runs across closure,
  and actual survivor UITextView identity with a strong reference.
- Windows static checks are not a build. Generation/build/full tests remain
  pending for this first implementation candidate. No GREEN claim yet.

## Boundaries

Both Pane/Session/Run owners survive resizing; closure never deletes or Stops.
Survivor native content must retain identity and continuously expand. Device
comfort, thresholds, haptics, VoiceOver usability and performance await the
owner's final whole-Stage review and later physical-device test.

## Review regression execution ruling — 2026-10-04

Ruling: after the full compiled S5-10 initial RED, use an explicit, branch-limited
`review-red` CI profile for the three additional unit regressions (missing lazy
Turn receipt, concurrent source Recent ratio, Single Card New cleanup). App build
and the entire unit target remain mandatory. The selector rejects arbitrary flags;
main and absent-profile runs always include UI. Remove the JSON profile before the
corrected production candidate and full S5-10 GREEN gate. This reduces repeated UI
waiting for unit RED; it is not acceptance evidence. Test compilation failures in
37143212009, 37144137510 and 37144774516 are recorded as compilation failures,
not behavioral RED. The latter app build passed; its test needed `try` on the
throwing runtime projection.

### Review RED receipt and correction candidate

Remote 816c0f9ccfb6418e8cb99cbc3a0ae170604cbf6b / tree
14575a185a571afe2be9b66661ee1baa785edcd7 compiled in 37146073242
(job 111270190792). Exactly three behavioral issues among 846 Swift tests:
stale lazy receipt completed, source Recent reset 0.63 to 0.55, and Single
Card New retained `.primary` preview slot. All 20 XCTest passed; no UI tests
were selected for that review-RED run. The correction pairs a measured target
with its layout revision, materializes a missing retained Turn, preserves the
current arrangement ratio, and restores no-Split presentation cleanup.
The temporary JSON profile is removed for the full correction gate. Also
filter unavailable accessibility close actions and instrument native Lift
readiness so Browse tests wait for actual eligibility without retrying gestures.
Full generation/build/unit/UI GREEN remains pending.

Full candidate c80660f / tree ee6ef86a6a866123d31eba8b6984928b5a370969
passed app generation/build in 37146884356, but its full test step failed
before xcodebuild: macOS Bash 3 treats the empty TEST_ARGS array as unbound
under nounset. Correct the argument array to always contain the `test`
subcommand and append only fixed selection flags. This failed script run
provides no unit/UI result for the corrections. Source review of the fixed
S5-10 commit found no confirmed P1/P2 blocker.

### Full correction gate and repeated resize repair

Full remote c7424eefdf4cc63e0d4fcf115db4b10f07954dde / tree
06a24e07ad956938d2aab8d0c3e5b630a6c74fe7 built in PR 37147217012
and push 37147213766. All 846 Swift and 20 XCTest passed. Both full UI
runs executed 35 tests and reported three failures in two resize tests:
blank-background keyboard dismissal failed before the draft drag, and a
second resize was not admitted after the first successful resize.
No test host restarted. S5-10 remains unverified.

Do not manufacture a new layout revision when the ratio is unchanged.
The pan's last geometry has already been measured; releasing at that same
ratio must use its existing revision. Also explicitly make the ScrollView's
blank rectangle a tap target so the blank-background dismissal gesture can
receive margin taps. Keep the repeated drag and actual keyboard/draft UI
assertions in the full correction gate.

### Native boundary diagnostic run

Remote c9841a1f045556d7802e2eadb257dd6deacc0948 / tree
4d5f1d1c7027530e866e97c0ed4ceaf9b3014a2c built successfully.
Push 37149516942 / job 111280233296 passed all 847 Swift tests and
20 XCTest, but repeated the same three failures in two resize UI tests.
PR 37149519510 / job 111280237417 executed the same failing UI cases
before its 30 minute timeout cancelled final collection. Neither is GREEN.

Ruling: collect DEBUG-only blank tap classification and per-Pane accepted,
measured, prepared and final layout revisions through accessibility probes.
UI logs explicitly read these probes around the failing actions. No input
text or secrets are logged. An exact, branch-limited resize-diagnostic profile
runs all unit tests and the five SplitResize UI cases once to locate the fault;
it is not the complete slice gate. Remove the profile before full GREEN.

Diagnostic head 13ce8fc715e06f80e6c4dd64969be5dd9249d90f / tree
8fb4c12b9d7e58f1e73d636bebf4424b2f1b8242 compiled in PR 37151688378
(job 111286746425): 847 Swift and 20 XCTest passed. Three resize UI
cases passed; the blank tap still failed. The two diagnostic reads failed
because SwiftUI did not expose the background probes in its accessibility
tree. That run does not supply the intended tap/receipt evidence.

Read-only source review confirmed an ownership boundary defect: the native
host installs its root once, so a primitive revision injected outside that
root remains frozen. The model's final revision then cannot match Timeline's
ack. Read and inject the observable revision inside WorkspaceHostedContent's
body instead, retaining its native subtree. Retrieve diagnostic values through
the already mounted native Surface probe without requiring a background
accessibility element. The blank-tap cause remains pending measured evidence.

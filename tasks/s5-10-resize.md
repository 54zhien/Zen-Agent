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

Correction 3dd91d7a154e41e3cd3b93a5121afc7e785b7566 / tree
f8c4b0c941687609ac759203b4aee460a32a9780 compiled in PR 37152568925
(job 111289307684): 847 Swift and 20 XCTest passed, but the same two
resize UI cases still failed. The native Surface probe was readable; no
background diagnostic UIView was mounted in its hierarchy, so it still
provided no Timeline receipt. The secondary editor center hit a native
large-title view while the source keyboard was present. This does not prove
the exact fixed blank-tap coordinate's hit or classification.

Read diagnostic state directly from the existing per-Pane scroll bridge
through the Surface probe. Record the actually observed, accepted and
measured revisions at their callbacks, and native ScrollView frames/hits;
print the XCTest coordinate too. Remove the inaccessible background probe.
No further production behavior change is made until these boundaries are
measured. Full GREEN remains pending.

Direct diagnostic d84a85868c8f54641a50d3b773f72bb49a03f8ee / tree f61d21157a62926a268b705e59baa743e8c23e73 in push 37153479357 (job 111292177480) built and passed 847 Swift plus 20 XCTest. The same two resize UI cases failed. Both Pane revisions matched 3; the source lease completed, but the empty secondary awaited target 127 at offset 0. The fixed blank point hit NavigationBarContentView. Capture raw SwiftUI/native content size, offset, insets and container before changing the converter; move the actual touch above the measured Composer rather than the navigation title.

### Measured conversion correction

Raw diagnostic b5f1ebbeff6564569f651d5a8853b484ff06c943 / tree
f0ccc4d3954fbe2e5e5c845be17fe52a2cd16ecd built in push 37155136930
(job 111296898657), passing 847 Swift and 20 XCTest. Five resize UI cases
ran once; three passed and two failed. The measured Timeline-margin touch
classified blank=true and dismissed the keyboard. The remaining draft test
then failed a global AX index for the empty resting editor; both native hosts
still retained their actual editor. Tap the measured native location and
verify its first responder plus draft value and identity.

The geometry contract is now measured, not inferred from documentation:

- Empty secondary: native bounds height 377, adjusted Insets 116 + 108,
  content height 56, raw offset -116; SwiftUI container height 153.
- Source at native bottom: native height 437, adjusted Insets 116 + 74,
  content height 2042, raw offset 1679; SwiftUI container height 247.

`containerSize` already represents the usable viewport after Insets. Keep it
and the top-normalized offset, but use contentSize alone for model height.
The empty maximum becomes 0; the source maximum becomes 1795, exactly its
observed raw offset plus topInset. Adding Insets to content while comparing
it against the inset viewport double-counted them. This is consistent with
Apple's total-scrollable-space definition when both sides use the same
coordinate convention. Source: https://developer.apple.com/documentation/swiftui/scrollgeometry/contentinsets

Two production-mapper unit regressions preserve these observed fixtures.
The existing compiled resize and bottom-request RED motivated the correction;
these new unit regressions have not had a separate test-only CI run. Retain
fresh revision/geometry/scroll acknowledgements without synthetic success.
Read-only source review agreed with the measured conversion correction.

Remove the diagnostic JSON and restore the full suite for the correction gate.
The full job cap is 40 minutes because prior full CI executed all 35 UI cases
but exhausted 30 minutes during collection; no retries or loops are added.
Generation/build and full unit/UI results remain pending.

### Full correction gate and AX query follow-up

Correction c3c2cbad9cc403dcb37f18ecd09327a0fa3385f6 / tree
72b8d93a900fa8b86cfadf0a08eb309acb27e972 built in push 37156554573
(job 111301103732). All 849 Swift tests and 20 XCTest tests passed.
Thirty-five UI cases ran once; 34 passed. The repeated reading-anchor resize
now passed. The remaining dual-draft case tapped the measured secondary
editor and verified its actual first-responder state, then failed the draft
query: XCTest reported legacy TextView versus modern StaticText automation
type for _AXUITextViewParagraphElement.

Query the user-entered draft by identifier and value/label across AX types,
while retaining both native editor identity and owner-count assertions.
Native diagnostics add window frame and UTF16 text length, never text content,
to distinguish a query failure from lost input. No Composer behavior changes.
This follow-up still requires a full build and test gate; no GREEN is claimed.

### Measured small-Pane editing defect

Follow-up 8d8135cee591fe4afeb261190bfa1809595e5c95 / tree
d9f992f8d988bca3d04537f268e5986682512496 built in push 37158048864
(job 111305511104). All 849 Swift and 20 XCTest passed; 35 UI cases ran
once, with two assertions failing in the same dual-draft case.

The host-local measurements refute a query-only explanation. After typing,
source retained 19 characters and secondary received its own 22 characters
with focused=true, but its native editor frame was (28, 527, 346, 1).
Its Timeline container height was zero. The input and reading viewport were
actually clipped away while the keyboard occupied the lower fixed Pane.
Do not replace this failure with a looser content query.

Publish constrained-height geometry regressions plus a native readable-line
assertion before correcting production geometry. The explicit review-red
profile runs all units for this RED receipt; it is not the full slice gate.
Diagnostic fields record the Composer bounds/keyboard guide/surface/viewport
and actual font line height without logging text. The correction must retain
one editor and respect the native keyboard region, preserving Split ratios
and both draft/reading owners. Full generation/build/unit/UI GREEN remains
required before S5-11 product work.

Test-only candidate 6177fd609ffc7d691a2335420a33d6a8f96cd194 / tree
2a700ef75a9df09c56ed140e74be491e2c0dee2c generated and built the app,
but PR 37159749888 (job 111310580273) failed compiling the UI diagnostic's
chained optional CGFloat conversion. The new unit regressions did not run.
Replace that parser with explicit typed steps, retaining the same assertions;
this is a compile repair, not behavioral RED or a product correction.

### Constrained viewport correction

Compiled RED 09b567d19ccf71c5fe35d2a0496362011495a50c / tree
a1fa5b45b8af7244be0dafae91afdd59c2328fb7 in push 37160044669
(job 111311446654): generation/app build succeeded and all 20 XCTest passed.
The single Swift Testing run executed 851 tests in 127 suites; only the new
constrained-Pane suite failed, with nine issues across its four height arguments
and scaled-line case. At availableHeight 146, text height was 1.16 instead of
22. This preserves behavioral evidence before correcting the production cap.

The correction floors the preferred editing cap at top padding + control rail
+ one scaled line, bounded by the actual available height minus bottom spacing.
Normal large-viewport fractional caps stay unchanged. The older 180 pt fixture
asserted the fraction even when it clipped a line; it now checks the actual
height budget and a readable line instead.

The full 8d8135 native UI receipt also showed the lower Timeline at zero usable
height. Both outer Workspace modifiers previously ignored all safe-area regions,
so Split kept full-screen slots while the keyboard covered the lower slot.
Ignore only container regions there; preserve the Composer's native keyboard
guide and its inner keyboard-region modifier. Saved ratios and Pane/Run owners
are unchanged. Apple's current definitions distinguish container and keyboard:
https://developer.apple.com/documentation/swiftui/safearearegions

Source review found no concrete double avoidance blocker, but requires measured
GeometryProxy size/insets and final Split viewport to reject double subtraction.
A DEBUG-only geometry receipt records those values. The existing dual-draft UI
case now also requires both Timeline containers to retain one readable line
during secondary editing, retaining real editor identities and native text lengths.
Run all units plus the five resize UI cases once under resize-diagnostic; that
diagnostic receipt is not slice acceptance. Remove the profile for the full
generation/build/unit/UI gate after resolving any measured integration failure.

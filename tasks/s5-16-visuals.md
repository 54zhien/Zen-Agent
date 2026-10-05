# S5-16 Visual reinforcement — implementation and validation record


## Current source gate — FULL CLOSED; fresh review complete

Tested local174c23cad7e9bb1fda698e6fcab166cf5a9dde20 and published
remote db30ed60a1c4c164f03892b8421b0351a7d45bf4 have identical tree
79f55ccb5d2ff9558eaae8e5111830f409ecca91. Profile is absent.
Both full push37247975877 and PR37247978542 plus guard37247978538 passed
real macOS XcodeGen/build,942Swift/151suites (74.272s/80.325s),20XCTest,
54phoneUI (one expected Pad-only skip,zero failures;1413.836s/1424.781s)
and the separate actualPad case (107.610s/173.815s). One Swift test-run start
and no host restart/retry in each. Native Files cancellation, Settings Save/
first Send/Soul Close, Ink controls and all Workspace regressions passed.
The fresh read-only [whole-stage review](stage5-code-review.md) compared main
eec3eb3 to this source, inspected integrated foundations as context, and found
no concrete Critical/Important/Minor code findings. No focused repair was requested.
Draft PR33 remains open/unmerged; physical acceptance remains OPEN.
The rest of this record preserves chronological RED and failure evidence.

## Native behavior RED observed before production

Settings FULL closed at remote2d501a6be6a39ee1194a3302c1e5241e23771fb8,
tree437d5de40a08affbb25dd341db8d9dc9e519a3f5,local4025b41. Both complete
runs37236474441/37236477630 and guard37236477646 passed; see S5-15 record.
Branch codex/s5-16-visuals begins from that exact source, stacked on draft PR32.

First publication adds the real existing-API CurrentCardEdgeTests and an actual
Appearance UI regression. The native edge must fit its cropped Surface, remain
one layer through repeated poses and disappear in Full. The UI reaches existing
Settings/Appearance before expecting missing Ink controls; after implementation
it will verify persisted controls, real dark-mode effects and repeated native
Lift/Return preserving Current identity,editor,draft and one Composer.

The fixed-branch visuals-red profile runs the complete unit target and all
Settings UI; actual Pad remains unchanged. Its local scope guard first failed,
then passed12 tests after the fixed mode was added. This local configuration
check is not product behavior RED. Real macOS XcodeGen/build and native behavior
failures must precede production effects. The new Motion policy test draft is
excluded until its actual type exists; missing symbols are not behavior RED.
No renderer/edge production implementation is in that RED publication.

Both RED runs completed XcodeGen and real app/test builds. Push37239980587
ran931 Swift tests/148 suites in99.175s; PR37240008961 in105.126s. Each
recorded exactly2 CurrentCardEdge issues (missing sole layer and required path).
Each also passed20 XCTest and the original3 Settings UI; the new actual
Appearance test failed only because the Ink switch was absent. UI totals4,
one failure,181.685s/150.804s. Actual iPad passed102.855s/110.456s and
guard37240008951 passed. One Swift test-run start, no host restart/retry.
Raw RED logs remain in the external handoff directory.

## Implementation history and recorded failures

After the genuine RED, a native opaque canvas owns one root and two radial
gradients. Gesture samples change only bounded reverse displacement/intensity;
they do not restart keyed slow flow. Live scene, Reduce Motion, low power and
thermal policy freezes flow/parallax, keeping static dark Ink. Window detachment
also removes animations. Light mode or disabled Ink uses a static background.
Actual Settings controls persist through the existing Appearance owner.

SurfaceClipView owns one faint Current-only semantic outline above hosted content.
It follows the real visible crop/corner radius, matches Browse crop settlement
with one bounded path animation, clears that work on replacement/cancellation
and hides in Full. No new gesture, Timeline, session, Router or Runtime owner.
Native tests exercise layer identity, real animation keys, window lifecycle,
policy changes, finite bounds, crop replacement and preference reload.
The actual Settings UI exercises enablement/intensity, dark mode, two Lift/Return
cycles with native retention across Settings and warm-owner/draft restoration
across Preview. The results and remaining FULL gate are recorded below.

First implementation2c7e389/treeae22891 built in both37241606003/37241608585:
942 Swift/151 suites passed78.796s/99.922s,20 XCTest passed; actualPad passed
103.388s/109.186s,guard37241608686 passed. Each4SettingsUI had7 assertions
in the new Ink case; original3passed. UI316.093s/281.972s; no restart/retry.
Native artifact11317838918 and its screen recording show that the Form-wide
Switch AX element's native tap at201,287 missed the actual right-side switch;
enablement stayed on. Give the switch its own labeled interactive bounds.

The two editor-identity failures were an incorrect new test contract, not evidence
for changing S5-04. AppShellModel.enterPreview deliberately unregisters/releases
the Full Pane, preserving its warm Session; PreviewHandoffUITests explicitly
requires editor dismantling and native remount with draft/anchor restoration.
Correct the assertion boundary: Settings Close retains the same native editor;
Lift/Return retains actual Session, Composer and reading owners and draft, with
one newly mounted editor. A DEBUG diagnostic reads these actual owners. Keep
the existing native remount and reading-frame tests; do not retain hidden Full
editors or change Runtime/SessionStore ownership to satisfy the mistaken test.

Native-switch candidatec009e260/tree4b383e09 passed app build but both actualPad
jobs111555982911/111555987210 failed UI test compilation:4 missing explicit
self captures in escaping expectation closures at SettingsUITests44/81/82.
Runs37243238022/37243239839 and guard37243239823 are retained. This is a
test-source compiler error, not another behavioral RED or a product result.
The next candidate adds only those4 self qualifiers; all assertions and
native-switch production source stay intact. macOS gates must run again.

Explicit-capture candidate893cd1ff/treee7dd784b passed push37243724437 build,
942Swift/151suites81.922s,20XCTest,actualPad103.838s and guard37243726990.
Original3SettingsUI passed; new Ink case stopped at its actual switch-off
assertion,4UI/1failure154.433s. PR37243726991 completed942Swift/151suites
95.199s,20XCTest and actualPad97.611s; Soul resting/focused UI passed. Its Ink
case had the same switch-off failure. Startup additionally failed3 assertions:
after actual Save, configurationComplete was absent, then Send was absent.
4UI/4failures222.301s. Save failure remains under native artifact11318991136
investigation; do not assign an unproven cause or report the PR GREEN.
Native AX dump in the push log identifies the precise hierarchy:
outer Switch idsettings-ink-enabled frame16,261.3,370,58 contains a native
Switch child frame309,276.3,63,28, value1. The HStack/labelsHidden attempt did
not change the Form wrapper's bounds. Revert that unnecessary product layout
and query/tap the real descendant Switch with positive, contained, hittable
bounds. No coordinate substitute, direct preference mutation or fake activation.

## Approved bounded design and device limits

This authorized slice follows the Settings full code gate. Production work began
only after the real native behavior RED above.

Blueprint requires restrained cool-black Ink, independent slow flow, tightly
bounded reverse parallax and a faint Current-only edge fitted to its visible
crop. Preserve native navigation, selected identity, reading ownership and the
approved card stack in both orientations. Light-mode Ink remains off pending
an explicit palette decision.

Use fixed small opaque native layers and keyed reusable animations. No
per-frame SwiftUI timer, accumulating animation loop, full-screen live blur or
unmeasured shader work. Consume existing Browse displacement and actual Surface
geometry; clamp finite reverse displacement to a small range. Reduce Motion
keeps static Ink and removes flow/parallax. Low power, serious/critical thermal
pressure and inactive scene freeze motion under the same observable policy.

The native Current outline follows the actual visible crop, stays above the
opaque content, does not duplicate on historical projections and hides in Full.
Keep bounded layer count through repeated geometry, selection and appearance
updates. Settings enablement/intensity applies through the retained observable
appearance/effect owner.

Publish genuine native visible-edge behavior RED before production changes.
Verify crop fitting, Full removal, layer identity/count, finite saturation,
policy changes mid-gesture and selection/Return preservation; pass full macOS
generation/build/unit/UI/actual Pad gates. Reconcile all stacked PR heads and
records in the whole-stage review handoff. GPU/energy/frame pacing, comfort and
VoiceOver acceptance require the owner's subsequent physical-device pass.

## Native Save activation repair after recorded Startup RED

Candidate893cd1ff PR37243726991 failed the real Startup Save path. Artifact
11318991136, video E5BE6FEF-964E-48D5-9AE5-AD42A073AB3F at31/35s, shows
an enabled Save button, idle unsaved status and the entered masked key after
the native row-center tap. ProviderSetupModel.save() synchronously clears the
input and enters saving at action entry. Those unchanged pixels show that the
action was not activated; no credential-store failure is established.

The small repair makes the existing Save label fill its Form row with a native
rectangular content shape. The existing synchronous action, account commit,
credential compensation and focus ownership remain the same. Stable Save/status
identifiers let the UI wait for actual enabled admission, tap the real button,
then require its real status to become configurationComplete. A failed Save
returns immediately with native diagnostics rather than producing Send cascades.
No coordinate tap, direct preference write, mocked save, retry or timeout increase.
The earlier compiled failure is the behavior RED for this repair; this revision
requires its own generation/build and all Settings UI before the FULL gate.

Native leaf candidate d05b532a4dfc28f74f3f88bb86558455aa375950 / tree
 e77cdea08d289f4d04f28df0e8df564715837db9 completed both targeted gates:
push37245337008 and PR37245338938, guard37245338964 all passed. Each built
942Swift/151suites (100.115s/76.664s),20XCTest and all4SettingsUI with zero
failures (262.402s/184.220s); actualPad71.687s/87.517s. One actual Swift-run
start, no host restart/retry. The descendant native switch now toggles real
preferences; Ink visibility/flow/edge, persisted intensity, two Lift/Return
cycles, warm-owner identity, draft and native editor retention across Settings
Close pass. The Save hit-area repair above still requires its own targeted gate
before profile removal/FULL. Earlier failed candidates remain recorded.

## Native Save targeted gate closed; FULL candidate

Save repair40c03f97a2628fdcad9e3bea05b5ccfbbe2d2a82 / tree
 dbac452f2dff2a000a0a8e90930c0b3c55196a33 passed push37246708991 and
PR37246712273,guard37246712207. Each completed XcodeGen/build,942Swift/
151suites (89.989s/78.982s),20XCTest and all4SettingsUI with zero failures
(209.100s/192.914s). ActualPad passed87.135s/75.114s. One Swift-run start
and no host restart/retry. The actual native Save/first Send and both Soul Close
paths pass with the strengthened status guard; no fake configuration activation.

The next candidate removes .github/stage5-test-profile.json. All units and the
complete phone UI suite, plus the unchanged actualPad axis job, must pass before
this slice's FULL code gate closes. README, plan and whole-stage handoff now
reflect implemented source and real targeted receipts. Fresh whole-stage review
follows FULL success. Physical profiling/comfort/accessibility remain OPEN.

## Final review and documentation closeout

The fresh reviewer inspected cumulative S5-05–16 changes and integrated Stage5
foundations, including ownership, cancellation, stale results, native restoration,
Files leases, Settings credential/account/Soul scopes and native visuals. Its
report is preserved in stage5-code-review.md; static review adds no device evidence.
GitHub's commit API independently confirms the published db30ed60 commit tree
79f55ccb5d2ff9558eaae8e5111830f409ecca91, matching the reviewed local tree.

The first closure commit ab5cd44/tree d4ffc8b changed documentation only.
Its push Pad passed90.066s, but PR37252198078/job111581981090 compiled and
ran the real case with one failure at WorkspacePadAxisUITests:33: the global
app.frame landscape query stalled until its waiter expired. All later actual
axis/drag/ratio/editor assertions passed (113.271s total). The failure is retained
with raw log, xcresult artifact11321566067 and video; it is not a second GREEN.

The focused [Pad readiness review](stage5-pad-readiness-review.md) supports
sampling each actual Pane frame once per poll, validating finite positive
rectangles, and requiring their union width>height. This changes only the test
observation. All native axis/drag/ratio/editor assertions, the app-coordinate
drag anchor, timeouts, skips and no-retry policy remain intact. App,Config,
Resources,project.yml and CI are identical to the reviewed tested source for
that Pad correction; the separate DEBUG-only diagnostic addition is below.
The test+documentation correction requires its own profile-free FULL pair,
actual Pad cases and guard. Its exact local/remote HEAD,tree and final CI receipts
are recorded in PR33 and the external handoff rather than a self-SHA doc loop.
No merge/main push/IPA; physical acceptance remains open.

That documentation candidate's phone outcomes are complete: push passed
942Swift/151suites107.282s,20XCTest,54UI (one expected Pad-only skip,
zero failures)1293.246s. PR units passed100.195s, but54UI1437.999s recorded
two errors in one older Browse case: initial Lift never entered Card at line19,
then swipeRight failed because no Card existed. One Swift start/no host restart
or retry in each run; guard passed. Raw phone artifact11321804529 is retained.
Its synthesized event confirms(201,803)→(201,583),hold0.7s, valid editor center;
video remains Full. Evidence cannot identify an admission or cancellation reason.

The [focused Lift review](stage5-browse-lift-review.md) covers the evidence and
limited diagnostic addition. DEBUG plus the existing UI-test environment enables
a12-entry native gesture trace of receive/admission/start/refusal/terminal and
active invalidation, with boolean eligibility/geometry and no draft text. The
Browse test preserves the original input and ten-second Card assertion, prints
native input evidence, and stops on that failed prerequisite instead of issuing
an impossible swipe. No Lift threshold, policy, ownership, timer or retry changes.
This is evidence collection, not a claim that the historical Lift cause is fixed.
The combined candidate still requires its own FULL pair/actual Pad/guard.

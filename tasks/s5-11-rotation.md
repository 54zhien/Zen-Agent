# S5-11 device presentation and axis

## Execution ruling — 2026-10-04

Ruling: publish only rotation tests and guarded CI selection while S5-10's full
correction gate runs. Baseline local e1b16b51bcc2d61f579d0c06e05ab8f516b9212e,
remote c80660f601efbcf48e45ca5ff8852bec208b66b5, tree
ee6ef86a6a866123d31eba8b6984928b5a370969. No S5-11 product implementation
starts until that full S5-10 gate and review pass. Any S5-10 correction is
propagated to this branch and its evidence refreshed before proceeding.

The explicit orientation-red profile is valid only on this slice's exact branch;
it selects the entire unit target and the production-root rotation plus
cross-owner Return receipt UI tests. It accepts no arbitrary flags. Main/absent-profile remain full. Remove
the profile for the S5-11 production candidate and full unit/UI acceptance gate.
The cost if wrong is an extra test-only run, never weakened product acceptance.

## Scope

Task 2 of the resize/orientation plan: iPhone landscapeSingle retains both
logical owners and updates only the visible Pane; portrait restores saved ratio.
Landscape App Space stays a card stack. Selecting an occupied opposite Card
must hand off to its existing physical owner without briefly installing the
initiating Conversation underneath it. iPad axis selection is explicit, keeps
logical top/left and bottom/right ownership and separate ratios.

## Current evidence

Test-only candidate pending generation/build and compiled behavior. No S5-11
functionality, GREEN, device acceptance or merge claim.

### Baseline propagation

The first compiled behavior RED is preserved at test-only remote
f39baf09a01897a74b86d53929d593adf889503a / tree
0c456f6d6e5b708324d598a8b3e97a2f67179324 in CI 37147321072:
build, 846 Swift and 20 XCTest passed; two rotation UI cases failed four
assertions because landscape retained two editors and the wrong presentation.
This is test evidence, not S5-11 functionality.

Propagate local S5-10 906b76e, remote
c3c2cbad9cc403dcb37f18ecd09327a0fa3385f6 / tree
72b8d93a900fa8b86cfadf0a08eb309acb27e972 while its full gate runs.
This refresh adds no rotation production code. Preserve both exact-branch
guarded test profiles, all unit tests, the 40 minute full-job cap and both
new geometry regressions. Apply measured native editor/blank touch locations
to the rotation tests too. Product implementation still waits for S5-10 full
GREEN and propagates any further correction before proceeding.

Refreshed test-only 9a943de3a85fa4c8972d36afc400a9ba6cc3b6a8 / tree
bf753d616fdb125ef56ac6c9ec946dd7d4d4c3d0 built in push 37156852370
(job 111301913946), passing 849 Swift and 20 XCTest. The two rotation UI
cases failed four assertions; the landscape presentation case still fails,
while draft setup exposed the same secondary AX-type query failure as S5-10.
Propagate the type-agnostic query and host-local native draft-length assertions
from S5-10 remote 8d8135cee591fe4afeb261190bfa1809595e5c95. This refresh
remains test-only. The full S5-10 gate is still required before product work.

### Keyboard-safe baseline and Return receipt RED refresh

Previous refresh 71bd10e2cf3a98fe69934301c560a4eb49cda832 / tree
359e144bb600ed4b8173186a32d9bcc6b75946b4 built in push 37158128902
(job 111305748782). All 849 Swift and 20 XCTest passed. Both rotation UI cases
failed four assertions; native draft lengths were correct despite the lower
editor's clipped AX content, and landscape still retained both owners visibly.

Propagate local S5-10 cfb792b / remote ebea1d614ec9c377b2a7d69681142536209b7808 /
tree 0f9d280eafa8ae0141b558caf3fb1990b8463e94 while its diagnostic/full
correction gate remains open. This adds no S5-11 product behavior. The S5-10
production correction already passed 851 Swift and 20 XCTest in its partial
10ac75b receipt; that cancelled receipt does not constitute a full slice gate.
Any additional S5-10 correction must still be propagated before S5-11 implementation.

Add a portrait keyboard admission assertion: keyboard-shortened usable geometry
must not be mistaken for physical landscape. Device presentation must use the
window/scene's full context. Existing Card tests wait for actual native Lift
readiness rather than a fixed delay.

Add a third UI regression for the already-occupied selected owner. Its DEBUG
pause is requested only after the real native window-frame and fresh Timeline
layout/scroll receipt; it must not fabricate those receipts or mutate ownership.
While paused, the selected Preview remains visible, the target's original native
editor is attached to measure the final frame, and all Composer AX nodes and
input are suppressed. Resume must expose that same editable target owner.
The fixed orientation-red scope includes these three UI cases and all units.
The pause seam is not implemented yet: compiled behavior RED is required before
that handoff correction. No S5-11 GREEN or device/axis acceptance is claimed.

### Completed three-case RED and usable-viewport propagation

Remote 650779105060604cb6c0a5319a65767a9120954e / tree
65a93603bb41396ad3e74eee98569cde58ee4194 completed push 37161580922
(job 111315963146). Generation/build, 851 Swift tests in 127 suites and
20 XCTest passed. All three UI cases failed six assertions: the Return
receipt pause seam is absent, landscape still exposes the old two-Pane
presentation, and landscape editing cannot acquire the intended sole owner.
These are compiled behavior RED receipts, not product acceptance.

Propagate S5-10 local 2b3b180 / remote
b26101fbd3888d268f04be7f6e07e56ad71558ca / tree
4c0da19b46249a5d8668804e0c1f6743de47721a. The measured keyboard defect
was a second subtraction of Insets from the already-proposed Workspace size;
this baseline uses the explicit usable-viewport geometry contract. Retain
orientation-red and the fixed three-case scope. No S5-11 product work starts
until S5-10's full gate passes.

The propagated usable-viewport RED completed at remote
b2acb4f0c5910e604eb1bf3d88770df7408ca0fa / tree
99c5e50e24f0b42facd4fa25c6b66fa4026472df, push37162846369
(job111319706978). XcodeGen/build,852 Swift tests in127 suites and20
XCTest passed. Three UI cases failed eight assertions. Portrait draft and
keyboard admission now pass; the editing case reaches the actual landscape
one-editor/owner assertions before failing. The occupied Return still lacks
the receipt pause seam. This refreshed behavior RED uses the corrected S5-10
geometry and authorizes those product corrections only after the full gate.

Local baseline also merges S5-10 full candidate332d2a55416b6a6e03822556274db070db557319
/ treeba0268272439a59eb0f3fa43bd46618b34a89746. Keep orientation-red during
test-only propagation; remove it for S5-11 product acceptance. S5-10 full
CI37163392220 / PR37163394761 is pending.

S5-10 full source gate is now GREEN: remote332d2a55416b6a6e03822556274db070db557319
/ treeba0268272439a59eb0f3fa43bd46618b34a89746, push37163392220,
job111321329410 passed XcodeGen/build,852 Swift in127 suites,20 XCTest
and all35 UI tests. Source review found no remaining production blocker.
S5-11 product implementation may now proceed on that propagated baseline.

### Product candidate — full gate required

Implement window-context device policy, retained physical Pane hosts, iPad
axis selection and independent ratios. The cross-owner Return coordinator
retains an immutable selected Preview and strong target Pane through native
host/window/frame and fresh Timeline layout/scroll receipts. Measurement keeps
the native editor attached but hides its input/AX nodes; the origin proxy is
hidden synchronously before resetting the transform. Token, topology, owner and
window changes cancel stale work. The DEBUG receipt pause follows those real
receipts and does not supply them.

Rotation cancels any active divider lease, restores the start reading anchor
without discarding new content, and queues ordinary measured restoration for a
hidden Pane. This additional cancellation regression accompanies the product
candidate; it has not had a separate compiled RED run.

Remove orientation-red for full iPhone acceptance. Add an actual iPad simulator
job for native axis switching/resize and retained editor identity; its test must
execute without skip or host restart. Local YAML parsing, profile guard7 and
git diff --check pass. No S5-11 build/acceptance is claimed before CI returns.

### First product build and source review

Local86a044d / remotecd3b67d971ca47e73ebe7cabecc9ce1783a12ce5 /
tree277ecf4aabf8716a1ae947eda733cb0a18fcef48 passed macOS XcodeGen
and app build in push37166208777 (build111329523429); full tests are pending.
Source review identified one P2: an embedded Workspace can resize inside the
same UIWindow. Include its actual frame in resize cancellation. The local fix
and same-window regression passed re-review. Also make stale visibility receipts
explicitly invalidate their waiter into selected-owner restoration; this is a
defensive cancellation edge, not a confirmed normal-flow failure. Its unit test
asserts no successful stale receipt and no later reuse. These tests accompany
the product correction rather than a separate compiled RED.

Actual iPad PR37166210919 / job111329535395 ran one axis test without skip
or retry and passed. Parallel push job111329523414 ran the same test and failed
one width-growth assertion after the first LR drag; axis switches, ratio returns
and retained editor identities passed. The predicate short-circuits before lease
queries, so this does not establish a lease defect. Source review found no
controller defect explaining unchanged width. Keep that failure visible and add
DEBUG-only native pan admission/displacement/axis/ratio/controller diagnostics
plus both native Pane probes for the next candidate. Do not weaken the assertion,
add sleeps/retries, or claim S5-11 acceptance from one passing iPad job.

Both full phone jobs completed with XcodeGen/build and20 XCTest passing.
Push37166208777 / job111329523429 ran859 Swift in129 suites with2 issues
in the native snap-interruption Return case;39 UI ran with1 Pad skip and1
failure at landscape blank keyboard dismissal. PR37166210919 /
job111329535366 repeated those2 Swift issues;39 UI had1 Pad skip and3
failures (same landscape dismissal, an older Browse neighbor gesture and an
older Composer Chinese-input observation). Neither run restarted the test host.
The cross-owner native/Timeline Return receipt pause and landscape Card Return
passed in both jobs. Retain all failures; no S5-11 full gate is closed.

Source inspection identifies an initialization edge: the first native Workspace
context report can arrive after Current Card is already accessible and Return
preparation has begun. That first report establishes a baseline and must not be
treated as a changed context. Split preparation requires that baseline before
capturing its device destination; Single retains its existing raw-window fallback.
The native snap test now waits for actual Full settlement with a bounded deadline
instead of assuming800 ms is sufficient, retaining all late-snap/owner/transform
assertions. This is not a retry.

Rotation blank-touch diagnostics use the actual measured readable Timeline
rectangle, including native Insets. The previous landscape point was x866
on an874 pt screen and did not establish that it lay in the Timeline rather
than the safe-area margin. Require a native viewport, point containment, actual
blank classification and actual keyboard dismissal; preserve draft/owner checks.
The next full run must verify these facts and the embedded cancellation fix.

### Follow-up actual Pad evidence

Local5f7f721 / remoted40fd17532a580901bbc560acbb0bdda86563385 /
treee651c3d13605dcecb75a0cee88156b01f4174613 passed the push iPad
job111336038978 (CI37168368758): one test, zero failures/skips/retries,
124.488 seconds. Its actual Pan delivered76.5 pt and changed source width
from688 to764.5; both axis ratios and native editor identities survived.
PR37168371168 / Pad111336043761 failed the same first-drag width assertion.
The new diagnostic reports last=none: the native Pan received no callback,
with ratio0.5, resize inactive, axisAnimation nil and both Timeline leases
released. This rules out a ratio update rejected by an active resize lease in
that run. It does not yet prove which UIKit layer consumed the touch.

The next candidate adds DEBUG-only menu display/end-completion tracking and a
live native center hit-test diagnostic. After choosing an axis, the test must
observe UIKit menu completion and the divider owning the actual center hit
before starting its drag. No fixed sleep, retry, fake callback or weaker width
assertion is added. Keep a failed readiness assertion visible if the native
divider remains inaccessible.

Current Apple delegate/animator signatures were verified against primary docs:
https://developer.apple.com/documentation/uikit/uicontextmenuinteractiondelegate/contextmenuinteraction(_:willendfor:animator:)
https://developer.apple.com/documentation/uikit/uicontextmenuinteractionanimating/addcompletion(_:)

Both d40 phone jobs completed: push37168368758 / build111336038947 and
PR37168371168 / build111336043756 passed XcodeGen/build,20 XCTest,
861 Swift in129 suites, with no restart/retry. Native snap Return now passes.
Both ran39 UI with1 expected Pad skip and only1 failure, the landscape blank
keyboard dismissal. Older Browse and Chinese-input checks passed in both runs.
Cross-owner Return receipts and landscape Card Return also passed again.

The native ScrollView frame is874 pt wide while its SwiftUI content/container
is750 pt. Horizontal adjusted Insets are zero: the previous probe therefore
included the horizontal safe-area margins, and the x866 tap did not deliver a
new Timeline callback. Its old portrait blank=true diagnostic remained present;
it cannot prove a later landscape touch. The next candidate clips the DEBUG
readable probe by the larger of actual native horizontal safe Insets and
adjusted Insets, reporting both. It adds an actual raw-tap sequence counter,
incremented only by the existing Timeline gesture callback. The test requires
a fresh increment and real keyboard dismissal, then verifies blank classification.
This changes diagnostics/test coordinates, not production layout or tap policy.
S5-11 remains open until this candidate's full phone and actual Pad CI pass.

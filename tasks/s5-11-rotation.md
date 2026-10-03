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

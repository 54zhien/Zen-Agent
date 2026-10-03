# S5-11 device presentation and axis

## Execution ruling — 2026-10-04

Ruling: publish only rotation tests and guarded CI selection while S5-10's full
correction gate runs. Baseline local e1b16b51bcc2d61f579d0c06e05ab8f516b9212e,
remote c80660f601efbcf48e45ca5ff8852bec208b66b5, tree
ee6ef86a6a866123d31eba8b6984928b5a370969. No S5-11 product implementation
starts until that full S5-10 gate and review pass. Any S5-10 correction is
propagated to this branch and its evidence refreshed before proceeding.

The explicit orientation-red profile is valid only on this slice's exact branch;
it selects the entire unit target and the two new production-root rotation UI
tests. It accepts no arbitrary flags. Main/absent-profile remain full. Remove
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

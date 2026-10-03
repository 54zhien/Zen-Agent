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

# S5-10 Divider resize and closure

## Scope

Execute `Docs/superpowers/plans/2026-09-30-stage5-resize-orientation.md` Task 1.
Test-only baseline is local S5-09 `95b854e`, equivalent to remote `08e950ab` /
tree `1d66027b2b4875245ffc492e011f6128798c3ab0`.

## Current evidence

- S5-09 source passed generation/build, 837 Swift and 20 XCTest in both
  37137948804 and 37137951724; only the new ambiguous UI frame query failed.
- That test-query repair has fresh CI pending in 37139550698 / 37139554202.
- This test-only slice adds independent streaming/read-anchor regressions,
  Handle resize, line non-admission and both explicit close directions.
  The DEBUG identity probe exposes the actual survivor UITextView identity.
- Expected behavioral RED: static Divider does not resize or expose close
  actions, the broad line currently closes Split, and the reading machine
  combines a bottom reference offset with an unrelated top reference identity.
- No S5-10 production behavior has been implemented. Its product gate depends
  on S5-09 GREEN and compiled behavioral RED from this tree.

## Boundaries

Both Pane/Session/Run owners survive resizing; closure never deletes or Stops.
Survivor native content must retain identity and continuously expand. Device
comfort, thresholds, haptics, VoiceOver usability and performance await the
owner's final whole-Stage review and later physical-device test.

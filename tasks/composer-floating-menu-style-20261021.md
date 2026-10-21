# Floating primary menu appearance — 2026-10-21

Owner request: change only the keyboard-hidden primary + menu style. Use the current screen/window corner radius, medium-sheet labels/order/SF symbols/gray circles, allow larger size, and offset the expanded endpoint toward the lower left. Build and deliver IPA and its absolute path; do not run tests.

Blueprint ruling: `05df074abc0dfa5df26dfb8966431a2800533d2b` on the existing owner Composer design branch.

## Scope and choices

- ComposerActionMenuView uses one five-row sequence: Model, Thinking, Plugins, Images, Files (Chinese labels). Floating actions opt into the same 44pt scaled circular backgrounds and 25pt symbols as the medium sheet. Model/thinking behavior, capabilities, disabled entries and SF glyph implementation stay unchanged.
- Floating rows are 64pt scaled, with vertical/leading margins that keep corner-adjacent icon centers inside the new screen-radius outline. Maximum preferred width grows 250pt -> 300pt; short viewports retain existing scrolling.
- ComposerActionMenuPresenter resolves the primary expanded radius through the existing WindowCornerGeometry helper. Its primary endpoint shifts 8pt left and 20pt down, clamped within the window. Source/dismissal endpoints, durations, curves, glass/icon transitions and haptic triggers are unchanged.
- Child panels retain the prior 250pt placement proposal, corner radius, text layout, selection and transitions. The larger primary menu must not enlarge the children through the shared proposal.
- No changes to keyboard handoff, medium-sheet geometry, editor, Split or Sidebar.

## Validation

Static diff review and unsigned macOS device build/package pending. No tests or simulator visual probes will run. Device appearance remains pending.

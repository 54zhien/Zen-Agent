# Files close and retained Composer lifecycle — 2026-10-16

## Scope and preserved failure

Continue the owner's UI polish branch, preserve its failed evidence, validate the
complete gate, and build an unsigned device IPA. Do not merge `main`.

The starting candidate is `cacb2040ae8fb4a2060afcbd49080e67e43567a0`, tree
`9fe153a9091cb75907db7828b6ac43e592865c2f`.
[Original full CI attempt 1](https://github.com/54zhien/Zen-Agent/actions/runs/38868851144)
concluded cancelled, with actual Files UI failures before cancellation.
[Its packaging attempt](https://github.com/54zhien/Zen-Agent/actions/runs/38868851153)
correctly refused to build an IPA because the full gate did not pass. Neither
run was rerun or replaced by a claim of success.

The original import test first failed at FilesWorkspaceUITests.swift:109:
the Files page did not disappear after Close. Focus, keyboard, and missing
editor failures followed. The recovered recording confirms that the system
picker retired but Files remained. This is not evidence of an isolated
responder-restoration failure.

The cancelled xcresult lacks its final Info.plist, so normal attachment export
failed. Its original Data objects, staging logs, and recording were recovered
read-only and archived locally under
`C:\Users\Azusa\Documents\Codex\artifacts\2026-10-16-files-focus`.
The raw job log SHA-256 is
`74b042746ed9daf6e7641228fa00e5e25aae7a4750de269fe0df55ae0b5ba3fd`;
the recovered import recording SHA-256 is
`279d1169cbff7b570d955a25674b13f285a21c2dbba58a41ac154d138389e54a`.

## Diagnostic findings

No product behavior changed in these diagnostics:

- [Isolated Files diagnostic](https://github.com/54zhien/Zen-Agent/actions/runs/38876931647),
  source `3db1654f556d4e1da6adc5416534a2c5253fa161`, passed the original import
  and preview/export tests, the added no-picker close test, native overlay
  tests, and the actual iPad case. This did not reproduce the full failure.
- [Original-prefix diagnostic](https://github.com/54zhien/Zen-Agent/actions/runs/38878836749),
  source `ce591a958a3272f040277a82bb16d5ad1b99ced5`, passed 1,126 Swift tests
  in 176 suites, 20 app XCTest cases, the exact original 17-case UI prefix
  through Files, and the actual iPad case. Method names and order were checked
  against the original log. Gated observations confirmed native picker
  completion, matching presentation IDs, Close action delivery, matching
  overlay IDs, route dismissal, and restored native focus/draft.

These successes do not establish the cause of the original missed Close.
The observations and narrow workflow selectors remain on diagnostic branches;
the production candidate retains the complete original CI workflow.

## Proven lifecycle defect and repair

The original detached Composer receipt showed logical Resting with an unfinished
Collapsing phase. Source review found that a parked host could start a UIKit
morph solely because its retained bounds were nonzero, while an interrupted
completion was the only path that could settle its transport state.

[Native characterization RED](https://github.com/54zhien/Zen-Agent/actions/runs/38880841408),
source `dc7e3cc6f3ae21e9d4eb53d42894f3f911408b00`, built and ran the real native
Surface hide/detach/remount path. Both blur orders reached the post-remount
assertions and failed settled readiness. Blur delivered after detachment also
retained frame `(24,772,354,62)` instead of the original `(31,781,340,62)`.
There were three issues in the new parameterized test; the prior tests and
iPad case passed. No fixture ownership precondition failed.

The native fixture owns an explicit UIWindowScene window, restores the prior
key window, and serializes its window-using suite. Two earlier fixture drafts
were superseded and cancelled; they are not behavioral RED evidence.

The repair stays in ComposerHostView:

- Detachment resets transport to the current presentation state and invalidates
  the old generation, so a stale animation completion cannot own a remount.
- A configuration update off-window synchronizes its endpoint without starting
  a visible morph. Reattachment recomputes the window-dependent resting endpoint.

This changes neither focus intent nor the original editor, draft, IME guards,
overlay admission, or responder capability. It adds no refocus delay or retry.
The same settled-readiness, frame, identity, draft, and editor-usability assertions
remain. The UI regression also covers closing Files without opening a picker,
while preserving the original native import, dismissal, focus, and keyboard checks.
The final native regression also includes immediate remounts and waits for the
actual keyboard transition to finish before comparing resting geometry.

This repair targets a demonstrated retained-view lifecycle defect. Its causal relationship
to the original Files Close delivery failure remains unproven and must not be
reported as established.

## Final validation and delivery

The final packaging candidate must pass the unmodified full CI workflow on its
own first push attempt, including the added regressions and actual iPad case.
The existing IPA workflow then builds that exact commit and writes its SHA,
tree, CI run/attempt, build variant, and package hash into BUILD-INFO.txt.
Final exact-head receipts are kept with the delivery outside the source tree.
Simulator verification and an unsigned IPA are separate from physical-device
acceptance. No main integration is authorized by this repair.

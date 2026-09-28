# S5-02 — Static App Space geometry

Contract/whitelist: [implementation plan](../Docs/Plans/2026-09-28-s5-02-static-geometry.md).
Base `d68195ed6b963f2380b1548ae47f6642852252c8`, Blueprint `596a84d4b58769e3e7b838be95edcb43f9e0ec82`.
Owner continuation authorizes this next slice after S5-01/main CI, with serial integration gates retained.

## Behavior and boundary

Pure local geometry validates viewport/insets/typography minimums and caller identity.
Current remains right-biased, up to three previous cards form a left/top depth stack.
All emitted frames stay inside the safe viewport. Caller order remains unchanged;
exactly one New sentinel is appended logically rightmost. Selecting it produces a
normal value-only Current placement, not a Conversation record or Composer.

The bounded static window does not implement real preview virtualization. No
sorting/activity write, catalog query, transition/gesture, Runtime, Provider,
database, migration, Split or shader. Current plus previous-only preview samples
are DEBUG-only; production remains the existing Full Conversation entry.

Blueprint ratios/depth offsets are initial calibration values. Minimum dimensions
come from the caller; the sample uses Dynamic Type-scaled220×300. Asymmetric edge
padding (left twice right, right min16pt/2%available width) retains a right bias when
the minimum cannot fit. History spacing is constrained by local bounds with a small
rounding margin. Tiny-window containment does not establish content readability.
GeometryReader already has the safe content viewport in the sample; it passes zero
extra insets. Explicit asymmetric insets are independently exercised in unit tests.

## Verification history

- S5-01 main CI [36378968995](https://github.com/54zhien/Zen-Agent/actions/runs/36378968995), attempt1,
  passed XcodeGen/App build,662 Swift Testing/104 suites,20XCTest units,5UI tests on `d68195e`.
- `52fbccc9707ab9bf3d7b578d07551786a8b55a9c`, [36380036860](https://github.com/54zhien/Zen-Agent/actions/runs/36380036860),
  attempt1: App build passed, tests failed compilation in the Swift Testing allSatisfy(keypath) macro expansion. Not behavior RED.
- `832fbd0b5af1900d02648a1f1aeee052f71dbc48`, [36380531146](https://github.com/54zhien/Zen-Agent/actions/runs/36380531146),
  attempt1: compiled behavioral RED,668 Swift Testing/105 suites with36 issues, all from the new geometry suite;
  20XCTest units passed.8UI tests ran:3 new static-route failures expected; the pre-existing ComposerMotion test
  had one unexpected immediate text-value failure at line32 after typing Chinese. Send and later typing continued;
  no Composer/host implementation was changed. Keep this observation separate and require complete GREEN before integration.
- GREEN/current head/review result: [PR #17](https://github.com/54zhien/Zen-Agent/pull/17) carries the exact latest run/attempt/counts.

The first candidate is a deliberate compiled mutation (centered/full-size cards,
zero depth, wrong New order, no rejection), replacing no pre-existing API. The same
assertions remain for GREEN. UI route assertions ran before wiring was added.

Git write credential was unavailable; authorized connector publication uses an
exact local-tree comparison after fetch, before aligning commit metadata. No source
content is replaced; only intended paths are committed.

## Remaining acceptance

No physical-device geometry/readability/Dynamic Type/VoiceOver/rotation/performance
measurement is claimed. Static layout containment does not settle formal App Space
landscape behavior. Gate A/Stage5 remain open; real catalog/virtualization is S5-04,
browse/snap S5-05, explicit creation S5-06. Lift/Return begins in S5-03 after integration.

## Subsequent main CI

PR #17 merged at `e679abf2faf556d08f217795570f9f49077c4c14` after independent whole-branch
review found no Critical/Important/Minor issues. [Main CI36383328968](https://github.com/54zhien/Zen-Agent/actions/runs/36383328968)
attempt1 passed actual668 Swift Testing/105 suites,20XCTest units,8UI tests. Its tree
matches tested `48fdc62f4b3bee5693044350ed82f9711d26e44a`. Primary Desktop main synchronized
clean. Physical-device acceptance remains open. S5-03 proceeds separately.

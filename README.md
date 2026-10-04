# Zen Agent

Native iOS multi-provider Agent client / runtime.

**Product and architecture blueprint:**
https://github.com/54zhien/Zen-Agent-Blueprint

The Blueprint is private. Open it with an authorized GitHub account or connector;
an unauthenticated 404 does not mean that the design repository is missing.

The blueprint is the upstream design authority — product intent, architecture,
business semantics, security boundaries and the stage plan. This repository holds
the implementation. The relationship is one-directional: the blueprint defines
intent, this repository discovers reality, and reality that contradicts the design
gets fed back as a blueprint revision plus an ADR here. It is never resolved by
letting the code quietly diverge.

```
Blueprint  ──defines intent──▶  Zen-Agent
    ▲                                │
    └──discovers reality (ADR/tests)─┘
```

## Blueprint baseline

```
Zen-Agent-Blueprint @ 99d30b815651fe987bab9f88e269a84a89318625
Owner-approved Stage 5 supplement @ e6d8c5f9919a83672bea670bc7e49339e5f5373c
```

This is a snapshot of the design state this work started from, not a permanent
version pin. Update it when the blueprint changes in a way that affects
implementation. The Stage 5 supplement is
[Blueprint PR #5](https://github.com/54zhien/Zen-Agent-Blueprint/pull/5), still
draft/open/unmerged; it records the owner's Split Lift/Return, landscape and
Sidebar rulings. Design conflicts are resolved upstream in the Blueprint and
its `Design/ADR/`; engineering/tooling trade-offs belong to this repository's
`Docs/ADR/`.

## Status

As of 2026-10-05:

- Stage 0 and Stage 1 are closed; Stage 2 Runtime and Tool boundaries are on `main`.
- Stage 3 W1 wires the real App shell and text send/history. PR #12 added the
  reading-position/keyboard repair and UI harness. The owner reported its device
  Gate closed on 2026-09-27; D1–D7 observations and the exact installed build remain
  unverified in [the device record](tasks/stage3-device-acceptance.md).
- Stage 4 Prompt/Soul implementation passed its Gate and entered `main` through
  PR #10. See [the closure record](tasks/stage4-closure.md).
- [PR #14](https://github.com/54zhien/Zen-Agent/pull/14) is merged at `f775e63`:
  cold-start Run recovery, Provider finish handling, offline history, and Send
  activity timestamps. Its tested head is `8ee8516`; [PR CI](https://github.com/54zhien/Zen-Agent/actions/runs/36349052785)
  and the build-settings guard passed. Device verification of these repairs is pending.
- Stage 5 S5-01 is integrated on main through PR #16 at
  d68195ed6b963f2380b1548ae47f6642852252c8. [Main CI](https://github.com/54zhien/Zen-Agent/actions/runs/36378968995)
  passed; physical-device acceptance remains open in [the slice record](tasks/s5-01-surface-container.md).
- S5-02 adds static App Space geometry and DEBUG samples; see
  [the slice record](tasks/s5-02-static-geometry.md). Production navigation follows later slices.
- S5-03 Lift/Return is integrated through PR #18 at `aeaa05c`.
  [Main CI](https://github.com/54zhien/Zen-Agent/actions/runs/36401064255) passed
  generation/build,689 Swift Testing,20 XCTest unit and11 UI tests. See
  [the slice record](tasks/s5-03-lift-return.md); physical Gate A remains open.
- S5-04 is integrated through [PR #19](https://github.com/54zhien/Zen-Agent/pull/19)
  at `70c5c17`; [main CI](https://github.com/54zhien/Zen-Agent/actions/runs/36466689960) passed.
  including Session/LRU ownership, bounded history previews and native-editor
  Preview/Full handoff. One whole-branch review found three Important; a single
  test-first fix pass has reproduced all three and added corrective source.
  Inspect PR #19 for its tested head/tree and integration receipt. See
  [the slice record](tasks/s5-04-preview-virtualization.md). Physical Gate A and
  device memory/comfort remain open. Upstream S5-05 remains Card browse/snap.
- H1 consistent history reads and cancellable Preview handoff are integrated
  through [PR #20](https://github.com/54zhien/Zen-Agent/pull/20) at `3505a2e`.
  [Main CI](https://github.com/54zhien/Zen-Agent/actions/runs/36531208778) passed
  generation/build,740 Swift Testing,20 XCTest and14 UI tests. See
  [the repair record](tasks/h1-history-handoff.md) for behavioral RED and failed
  source runs; PR #20 holds the latest exact-tree CI, review and integration status.
- H2 Preview error sources and localized unreadable summary rows are integrated
  through [PR #21](https://github.com/54zhien/Zen-Agent/pull/21) at `eec3eb3`.
  [Main CI](https://github.com/54zhien/Zen-Agent/actions/runs/36555411803) passed
  generation/build,746 Swift Testing,20 XCTest and14 UI tests after independent
  review and its test-first repair. See [the slice record](tasks/h2-preview-recovery-state.md).
- The owner authorized S5-05 development before physical Gate A on 2026-09-29;
  Gate A remains open. Card Browse / Snap is on unmerged
  [PR #22](https://github.com/54zhien/Zen-Agent/pull/22), with generation/build,759 Swift Testing,20 XCTest and16 UI tests
  passed at `9372dfe`, and independent review approved (no Critical/Important). See [the slice record](tasks/s5-05-card-browse-snap.md)
  for bounded projection/selected Return ownership and RED evidence.
  S5-06 New/Pin/Rename is implemented on stacked
  [PR #23](https://github.com/54zhien/Zen-Agent/pull/23), based on unmerged PR #22.
  Its first implementation candidate `9dcb508` passed full CI (778 Swift,20 XCTest,18 UI).
  Independent review identified one Important (same-process draft navigation after New).
  Its regression was reproduced before correction; repair candidate `99c323b` passed
  [full CI](https://github.com/54zhien/Zen-Agent/actions/runs/36595377400)
  (780 Swift,20 XCTest,18 UI). Final publication also applies the existing active-Run
  protection to pristine-page retirement; the latest exact-head result and readiness
  are recorded in PR #23 after its own full CI. One Rename prefill Minor is deferred.
  See [the slice record](tasks/s5-06-new-pin-rename.md).
- S5-07 Card Delete/Undo is on stacked draft
  [PR #24](https://github.com/54zhien/Zen-Agent/pull/24). Its reviewed clock and
  replacement-read repair source passed [full CI](https://github.com/54zhien/Zen-Agent/actions/runs/36624971027)
  (802 Swift Testing, 20 XCTest, 19 UI). Its final source/test revision passed
  [full CI](https://github.com/54zhien/Zen-Agent/actions/runs/36627442020)
  (803 Swift Testing, 20 XCTest, 19 UI), including the mounted accessibility Delete
  action. PR #24 holds the exact-head receipt after closure documentation.
  See [the S5-07 record](tasks/s5-07-delete-undo.md).
- S5-08 Split Targeting is on stacked draft
  [PR #25](https://github.com/54zhien/Zen-Agent/pull/25). Native top/bottom
  Composer drags, the live Surface preview and a captured Split drop intent
  passed [initial full CI](https://github.com/54zhien/Zen-Agent/actions/runs/36636116839)
  (809 Swift Testing, 20 XCTest, 21 UI). Read-only review identified target
  traversal, final-release sampling and accepted-Surface handoff gaps. The
  repair's test-only [RED](https://github.com/54zhien/Zen-Agent/actions/runs/36638889365)
  compiled and reproduced the traversal and handoff failures. A first repair
  candidate passed build, 20 XCTest and 21 UI tests; one new Swift test needed
  to await its native Return animation. The corrected tree passed
  [full CI](https://github.com/54zhien/Zen-Agent/actions/runs/36642873825)
  (814 Swift Testing, 20 XCTest, 21 UI). Re-review found two additional
  handoff/animation interruption risks. Their test-first repair passed
  [full CI](https://github.com/54zhien/Zen-Agent/actions/runs/36659735487)
  (816 Swift Testing, 20 XCTest, 21 UI), with the exact source/test tree recorded
  in [the S5-08 record](tasks/s5-08-split-targeting.md).
- S5-09 Split Container is implemented on stacked draft
  [PR #26](https://github.com/54zhien/Zen-Agent/pull/26), unmerged.
  Current exact tree `1d66027b2b4875245ffc492e011f6128798c3ab0` passed
  [full CI](https://github.com/54zhien/Zen-Agent/actions/runs/37139550698)
  (837 Swift Testing, 20 XCTest, 30 UI), including hidden-source restoration
  against a changed native viewport. Parallel PR CI had an intermittent older
  initial-Lift admission failure; it remains recorded in the PR and slice record.
- S5-10 Divider resize/closure passed its full source gate on stacked draft
  [PR #27](https://github.com/54zhien/Zen-Agent/pull/27), unmerged. Exact tree
  `ba0268272439a59eb0f3fa43bd46618b34a89746` passed
  [CI](https://github.com/54zhien/Zen-Agent/actions/runs/37163392220)
  (852 Swift Testing, 20 XCTest, 35 UI); see [the slice record](tasks/s5-10-resize.md).
- S5-11 device presentation passed its full source gate on stacked draft
  [PR #28](https://github.com/54zhien/Zen-Agent/pull/28), unmerged. Exact tree
  `96300c087a4d272d77b55c947336bcd9447b98a2` passed push37169724633 and
  PR37169727362: generation/build,861 Swift Testing,20 XCTest,39 iPhone UI
  (one expected Pad-only skip), plus one actual iPad axis test in each run.
  See [the slice record](tasks/s5-11-rotation.md) for retained failed evidence.
- S5-12 Sidebar is on stacked draft [PR #29](https://github.com/54zhien/Zen-Agent/pull/29).
  Its full source gate passed on tree `6c1b9095f933b111590025a6d0aadd9a6bfe3bd1`,
  remote `9218e8c7fc9e5a11baa53bafda4787fb962768c0`, push37180640443 and
  PR37180642485: generation/build,873 Swift Testing,20 XCTest,46 phone UI
  (one expected Pad-only skip), plus one actual Pad axis case in each run.
  No retry/host restart; earlier failed evidence remains in the slice record.
  S5-13 Search passed its full source gate on stacked draft
  [PR #30](https://github.com/54zhien/Zen-Agent/pull/30), unmerged. Remote
  `6a217da90153e04a5e0120195610aaae95ab9a35`, tree
  `81dfd8c48e3cb17a453749432fc0f6272bbdcb24`, passed push37195522196 and
  PR37195524247: generation/build,894 Swift Testing,20 XCTest,48 phone UI
  (one expected Pad-only skip), plus one actual Pad axis case in each run.
  Native query teardown preserves the original responder; no host restart/retry.
  S5-14 Files has compiled behavioral RED on stacked draft
  [PR #31](https://github.com/54zhien/Zen-Agent/pull/31). Its complete Workspace
  candidate at remote `c738ed3da7d107ea8906d59d21a98a13eb0b39af`, tree
  `94a1c6db6b3428c0e6150bd45ce13cf1040fd50f`, passed full PR37209436556
  (912 Swift/141 suites,20 XCTest,50 phone UI with one expected Pad-only skip,
  plus one actual Pad case). Same-source push37209433472 passed unit tests,
  native export and actual Pad, but import cancellation failed; the full Files
  gate remains open. See [the current resume handoff](tasks/stage5-review-handoff.md)
  before using older task snapshots.
  S5-15–16 remain authorized after that full gate, in order.
  Full-stage and physical acceptance remain open.
- The owner subsequently directed all Stage 5 physical acceptance to take place
  after Stage 5 development ends. Device gates remain open; the changed order
  does not establish device memory, performance, input, comfort or VoiceOver acceptance.
- Formal Settings IA and
  `Settings → Agent → Soul` belong to later Stage 5 slices; Memory, Skills, MCP and
  Subagent remain later stages.

The [Stage 5 entry record](tasks/stage5-entry.md) records the integrated baseline,
CI evidence, remaining device checks, and design decisions needed by later slices.
Use Git and CI for the current HEAD; evidence commits in these notes are historical
checkpoints. CI does not establish device performance or accessibility acceptance.

`App/Persistence/` remains a data layer. GRDB is confined to it, and the existing
repository guard must continue to fail the build if that boundary is violated.

## Getting started

Requires macOS with Xcode 26 (the deployment target is iOS 26) and
[XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
xcodegen generate        # produces ZenAgent.xcodeproj — generated, never committed
```

Then build and test:

```sh
xcodebuild build -scheme ZenAgent -destination 'generic/platform=iOS Simulator'
xcodebuild test  -scheme ZenAgent -destination 'platform=iOS Simulator,name=<device>'
```

`ZenAgent.xcodeproj` is a build artifact. `project.yml` and `Config/*.xcconfig` are
the source of truth — see `AGENTS.md` §3 and `Docs/ADR/0002`.

## Layout

```
project.yml              project structure (XcodeGen input)
Config/                  build settings — the single source of truth
App/                     application target
Tests/                   unit tests, including the persistence invariant regressions
Docs/ADR/                engineering decision records
Resources/               bundled assets (fonts, licences, manifests)
.github/workflows/       CI
```

`App/Persistence/` is the data layer. Beyond it, `App/` grows real module boundaries
only as real code arrives — no pre-created empty directories or placeholder protocols.

## Notes

- **Signing material and API keys never enter this repository.** `.gitignore` is a
  backstop, not a storage plan; the CI hygiene job asserts on every run that the
  expected patterns are ignored.
- Development happens on Windows with no local Swift toolchain, so macOS exists
  only in CI. Changes are verified by pushing and reading the real CI result —
  never by asserting that something "should compile". See `AGENTS.md` §4.

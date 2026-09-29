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
Zen-Agent-Blueprint @ 596a84d4b58769e3e7b838be95edcb43f9e0ec82
```

This is a snapshot of the design state this work started from, not a permanent
version pin. Update it when the blueprint changes in a way that affects
implementation. Any design decision this repository makes that contradicts the
baseline is recorded in `Docs/ADR/`.

## Status

As of 2026-09-29:

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
- H1 consistent history reads and cancellable Preview handoff are maintained
  separately on [PR #20](https://github.com/54zhien/Zen-Agent/pull/20). See
  [the repair record](tasks/h1-history-handoff.md) for behavioral RED and failed
  source runs; PR #20 holds the latest exact-tree CI, review and integration status.
  H2 follows its implementation gate. S5-05–16 are not implemented by this repair.
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

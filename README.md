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
Device feedback corrections @ 3b4b22c0df91be668406127c84c1822b359883c0
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

As of 2026-10-16. `main` is at `52a456b` (Stage 5 baseline merge, 2026-10-09).
This table is a summary: exact heads, CI run IDs, test counts and RED/GREEN
evidence live in the linked records and their PRs, not here.

| Stage / slice | Code | Device acceptance | Record |
|---|---|---|---|
| Stage 0 — project baseline | on `main`, closed | — | [todo](tasks/todo.md) |
| Stage 1 — Provider, persistence, prompt foundation | on `main`, closed | — | [closure](tasks/stage1-closure.md) |
| Stage 2 — Runtime and Tool boundaries | on `main` | — | — |
| Stage 3 — App shell, text send/history, reading position | on `main` | owner closed the Gate 2026-09-27; D1–D7 observations and installed build not recorded | [device record](tasks/stage3-device-acceptance.md) |
| Stage 4 — Prompt / Soul | on `main` (PR #10), closed | — | [closure](tasks/stage4-closure.md) |
| Run recovery / Provider finish repairs | on `main` (PR #14) | pending | [stage5 entry](tasks/stage5-entry.md) |
| H1 / H2 history handoff and Preview recovery | on `main` (PR #20, #21) | pending | [H1](tasks/h1-history-handoff.md), [H2](tasks/h2-preview-recovery-state.md) |
| Stage 5 S5-01 … S5-16 — App Space, Split, Sidebar, Search, Files, Settings, Visuals | on `main` (merge `52a456b`) | **all open** — the owner moved Stage 5 device acceptance to after Stage 5 development | per-slice `tasks/s5-*.md`, [review handoff](tasks/stage5-review-handoff.md) |
| Stage 5 device feedback / known-issue stability | unmerged `codex/*` branches | in progress | branch PRs |
| Stage 6 S6-01 tool policy, S6-02 action intent | unmerged branches `codex/s6-01-tool-policy`, `codex/s6-02-action-intent` | — | `tasks/s6-*.md` on those branches |

Known deferrals on `main`:

- One intermittent Composer/focus defect is deferred by owner decision after
  two bounded diagnostic attempts; its regression test stays enabled.
- Memory, Skills, MCP and Subagent are later stages.

CI passing does not establish device memory, performance, input, comfort or
VoiceOver acceptance. Use Git and CI for the current HEAD; commit IDs inside
task records are historical checkpoints.

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

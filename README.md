# Zen Agent

Native iOS multi-provider Agent client / runtime.

**Product and architecture blueprint:**
https://github.com/54zhien/Zen-Agent-Blueprint

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
Zen-Agent-Blueprint @ 6b12e460a5db3fabaaff8f39b4732bcb73fb6405
```

This is a snapshot of the design state this work started from, not a permanent
version pin. Update it when the blueprint changes in a way that affects
implementation. Any design decision this repository makes that contradicts the
baseline is recorded in `Docs/ADR/`.

## Status

**Stage 0 — establishing a real baseline.** No product feature is implemented yet,
and none may be until the Stage 0 gate is met.

Explicitly not started: Provider (DeepSeek or otherwise), AgentRuntime,
ToolRuntime, Conversation UI, App Space, Soul, Memory, Skills, MCP, Subagent.

The only code beyond the minimal app and its build/test baseline is the throwaway
persistence spike in `Spikes/`, which exists to decide between SwiftData and GRDB
before anything is built on top of either.

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
xcodebuild test  -scheme PersistenceSpike -destination 'platform=macOS'
```

`ZenAgent.xcodeproj` is a build artifact. `project.yml` and `Config/*.xcconfig` are
the source of truth — see `AGENTS.md` §3 and `Docs/ADR/0002`.

## Layout

```
project.yml              project structure (XcodeGen input)
Config/                  build settings — the single source of truth
App/                     application target
Tests/                   unit tests
Spikes/                  throwaway experiments; each documents its own deletion rule
Docs/ADR/                engineering decision records
Resources/               bundled assets (fonts, licences, manifests)
.github/workflows/       CI
```

`App/` stays flat during Stage 0 and grows real module boundaries only as real code
arrives — no pre-created empty directories or placeholder protocols.

## Notes

- **Signing material and API keys never enter this repository.** `.gitignore` is a
  backstop, not a storage plan; the CI hygiene job asserts on every run that the
  expected patterns are ignored.
- Development happens on Windows with no local Swift toolchain, so macOS exists
  only in CI. Changes are verified by pushing and reading the real CI result —
  never by asserting that something "should compile". See `AGENTS.md` §4.

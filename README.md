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

**Stage 0 is complete; implementation beyond Stage 0 is in progress.**

**Under the Blueprint's definitions, Stage 1 is in progress; it is not complete.**
The repository also contains partial implementation belonging to later stages — Stage 2
run-state, send-commit and tool-recovery concepts among them — and out-of-order
implementation is not evidence that the stage it jumped ahead of is finished.

The Stage 0 baseline remains in place: the persistence engine is GRDB
(see `Docs/ADR/0001-persistence-engine.md`), the schema and numbered migrator exist,
and the seven invariants behind that decision have regression coverage.

At the implementation baseline immediately preceding this documentation sync
(`5523ce0`), the repository also contains partial, tested implementation surfaces for:

- Provider contracts and shared types, including a `FakeProvider` and DeepSeek
  implementation under `App/Provider/`;
- credential storage and a Keychain-backed secret backend under `App/Credential/`;
- HTTP transport, SSE parsing, streaming timeout policy, and a URLSession-backed
  transport under `App/HTTP/`; and
- persistence support for provider instances, credential metadata, steps, streaming,
  tool calls, and deletion.

Their presence does not mean the enclosing Blueprint stage is complete or that an
end-to-end product runtime exists.

No implementation surface for AgentRuntime, ToolRuntime, Conversation UI / Composer,
App Space / Split, Soul, Memory, Skills, MCP, or Subagent is present in the tracked
`App/` sources at that baseline. Persistence records or recovery tests concerning
steps and tool calls are not an AgentRuntime or ToolRuntime.

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

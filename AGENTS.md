# Zen Agent — Coding Agent Entry Point

This is the **only production code repository** for Zen Agent: a native iOS
multi-provider Agent client / runtime.

Design intent lives elsewhere. **Do not implement from this file or from
assumptions.**

> **Design repository (upstream):** `Zen-Agent-Blueprint`
> https://github.com/54zhien/Zen-Agent-Blueprint
>
> Recorded baseline: see `README.md`. The baseline is a snapshot, not a permanent
> version — update it when the Blueprint changes in a way that affects implementation.

## Before writing any code

1. Read the relevant design note in the Blueprint. Start from its index,
   `Design/Zen Agent 开发规划.md`, and use `Design/CONTEXT.md` as the authority
   for terminology.
2. **Inspect the real state of this repository** — actual files, build settings,
   dependencies, tests, existing code. Never infer it from a design note.
3. Design the smallest change that satisfies the intent. Decide ownership,
   dependencies, failure and cancellation paths before writing the first line.
4. Implement one testable vertical slice.
5. Run `xcodegen generate`, build, and run the relevant tests. See §4 — you may not
   claim completion without a real build result.
6. If reality contradicted the design, update the Blueprint and record an ADR.
   Do not let the code silently diverge.

**The Blueprint defines intent; it does not define code.** Class names, field names,
pseudo-code and numeric values in the notes are not API design. If this repository
already has good equivalent code, reuse or refactor it. Do not create a same-named
class just because a note mentions one — that is the failure mode the Blueprint
itself warns about most often.

## 1. The Blueprint is the upstream design authority

The relationship is one-directional and must stay that way:

    Blueprint  ──defines intent──▶  this repository
        ▲                                │
        └──discovers reality (ADR/tests)─┘

Two failure modes to avoid, both symmetric:

- **Do not implement something the Blueprint contradicts** because it is easier.
- **Do not edit the Blueprint to match whatever the code happens to do.**

If they conflict, the procedure is:

1. verify the facts — current Apple documentation, protocol specs, a measurement,
   or a test. Not memory, not intuition.
2. explain the conflict.
3. implement the safer / more correct solution.
4. update the Blueprint note.
5. record an ADR here if the resolution is hard to reverse or genuinely surprising.

Two platform claims have already burned this project, so treat them as standing
warnings: conclusions drawn from *remembered* rather than *current* API capability,
and numbers Apple never committed to (there is no fixed background execution
budget — do not invent one).

## 2. Stages are not advisory

Follow the dependency order in the Blueprint's `Design/Zen Agent 开发规划.md`. Do not
jump ahead because a later feature is more interesting, and do not build scaffolding
for a stage that has not started.

**Current stage: Stage 0 — establish a real baseline.**

Forbidden until the Stage 0 gate is met:

```
DeepSeek or any other Provider
AgentRuntime
ToolRuntime
Conversation UI / Composer
Soul
Memory
Skills
MCP
Subagent
App Space / Split
```

The **only** code Stage 0 may add beyond the minimal app and its build/test
baseline is the throwaway persistence spike under `Spikes/Persistence/` — and only
the minimal test types that spike needs.

This boundary is not bureaucratic. The persistence engine is still undecided, and
anything built on top of the wrong choice gets rewritten. That is exactly the cost
Stage 0 exists to avoid.

## 3. XcodeGen is the project's source of truth

    project.yml + Config/*.xcconfig
                  ↓
            xcodegen generate
                  ↓
            ZenAgent.xcodeproj        (generated, not committed)

`.xcodeproj` is a **build artifact**. It is gitignored and regenerated on every
machine and on every CI run.

- **Do not treat `project.pbxproj` as an edit target.** It is thousands of lines of
  cross-referenced UUIDs, and hand-editing it is how iOS projects acquire conflicts
  that only surface at build time.
- Structure changes (targets, schemes, sources, package dependencies) go in
  `project.yml`.
- Build-setting changes (deployment target, Swift language mode, optimization,
  signing) go in `Config/*.xcconfig`.

Build settings written into `project.yml` would override the xcconfig values, so
policy is deliberately declared in exactly one place. Do not "helpfully" duplicate
`IPHONEOS_DEPLOYMENT_TARGET` or `SWIFT_VERSION` into `project.yml`.

## 4. Minimum bar after every change

Development happens on Windows; this project has no local Swift toolchain. macOS
exists only in CI. That makes the discipline stricter, not looser:

1. **Local static checks** — what you can verify without compiling: YAML validity,
   cross-references between `project.yml` and the workflow, path existence,
   `.gitignore` coverage.
2. **Commit and push** to a branch.
3. **Let CI build and test.**
4. **Fix based on the real CI result**, not on what you predicted it would say.

Never describe a change as working, done, or verified without a real build or test
result behind it. If you could not compile it, say so plainly and say what you did
verify instead. "It should compile" is not a result.

Keep CI fast. `main` requires: repository hygiene, XcodeGen generation, build, unit
tests. Integration, provider and UI test layers get added as the stages that need
them arrive — do not build a fifteen-minute pipeline during Stage 0.

## 5. Secrets and signing material

Signing material and API keys never enter this repository. `.gitignore` is a
backstop, not a storage plan — the CI hygiene job asserts on every run that these
patterns are ignored, but passing that check does not make committing a key safe.

- Distribution signing is configured in CI via GitHub Secrets / App Store Connect
  API keys.
- `Config/Secrets.xcconfig` is gitignored and optional; `Config/Secrets.xcconfig.example`
  documents it. Nothing in it may be required to build.
- Never put a real credential in a test, a fixture, a snapshot, or a log line.

## 6. Engineering discipline

- Do not build the app by appending to one file or type.
- Do not put unrelated UI, state, network, persistence, Provider, Tool and Runtime
  responsibilities into one View/ViewModel/Controller/Manager.
- Do not force artificial modularity either. Functionality and clarity come before
  file-count purity; empty wrapper protocols and pass-through managers that add no
  real boundary are as bad as the God Object.
- Plan ownership, dependencies, failure and cancellation before coding a feature.
- Comments explain *why*: invariants, platform or protocol constraints,
  compatibility, risk. Not what the next line obviously does.
- If a file or type starts accumulating independent responsibilities, stop and
  review its boundary before adding more.

## 7. Where decisions are recorded

| Decision subject | Location |
|---|---|
| product / security / design | Blueprint, `Design/ADR/` |
| engineering / tooling / implementation | **this repository**, `Docs/ADR/` |

Write an ADR only when all three hold: hard to reverse, surprising without context,
and the result of a real trade-off. Otherwise leave the reasoning in the code
comment or the PR. Do not duplicate a Blueprint ADR here.

## 8. Layout

```
project.yml              project structure (XcodeGen input)
Config/                  build settings — the single source of truth
App/                     application target
Tests/                   unit tests
Spikes/                  throwaway experiments; see the deletion rule in each
Docs/ADR/                engineering decision records
Resources/               bundled assets (fonts, licences, manifests)
.github/workflows/       CI
```

`App/` stays flat during Stage 0. As real implementation arrives it will grow
`Core/`, `Data/`, `Provider/`, `Runtime/`, `Tool/`, `Conversation/`, `Workspace/`
— organically, when there is real code to put in them. **Do not pre-create empty
directories or placeholder protocols to look architecturally complete.**

# S6-01 — Tool Policy pure rule kernel

This record belongs only to the isolated S6-01 branch. Stage 5 closure remains
with its original worktree. Stage 5 and Stage 6 are not declared closed here.

## Provenance and ownership

- Worktree: `C:/Users/Azusa/.codex/worktrees/8b9b/Zen-Agent`.
- Branch: `codex/s6-01-tool-policy`; remote: `54zhien/Zen-Agent`.
- Fixed base: `0c1122592b4112f136063e228c5d3376a8707853`.
- Base tree: `29ef04ccaf94cbbd439fce4d0f87860b0a11b740`.
- This managed worktree initially had detached HEAD `eec3eb3`; its clean checkout
  was moved to a new branch at the authorized fixed base. The S5 worktree's HEAD,
  branch, index and files were not modified.
- Blueprint spec: `3b4b22c0df91be668406127c84c1822b359883c0`, matching the fixed
  checkout's README. Tool Runtime blob: `9d961dc500d8b39bf1623e568becf347cf5239c7`.
- Source plan: [the branch's plan](../Docs/superpowers/plans/2026-10-07-stage6-policy-foundation.md).

## Allowed files

All changes relative to the fixed base are restricted to:

1. `App/Tool/Policy/ToolPolicyTypes.swift`
2. `App/Tool/Policy/ToolGrantScopeMatcher.swift`
3. `App/Tool/Policy/ToolPolicyEvaluator.swift`
4. `Tests/ZenAgentTests/ToolPolicyScopeTests.swift`
5. `Tests/ZenAgentTests/ToolPolicyEvaluatorTests.swift`
6. `Tests/ZenAgentTests/ToolPolicyTemporalTests.swift`
7. `Docs/superpowers/plans/2026-10-07-stage6-policy-foundation.md`
8. `tasks/s6-01-tool-policy.md`

The existing Registry, Runtime, built-ins, persistence, App shell, UI, Files,
Settings, Config, Resources, project.yml, workflows and shared handoff/todo stay
outside this branch's changes. The generated project collects the added files
through the existing App and unit-test directory sources.

## Evidence already observed

| Group | Exact source | Native evidence | Whole workflow |
| --- | --- | --- | --- |
| Fixed baseline | `0c112259` / tree `29ef04cc` | [37619427383](https://github.com/54zhien/Zen-Agent/actions/runs/37619427383): XcodeGen/build, 965 Swift tests / 156 suites and 20 XCTest passed; phone 58 tests, one expected Pad-only skip, three assertions in `WorkspaceRotationUITests.testLandscapeEditsBelongToTheLastActivePaneAndPortraitRestoresBoth` failed; actual Pad passed | failure |
| Scope RED | `17bcd251` / tree `7a780ba2` | [37622815846](https://github.com/54zhien/Zen-Agent/actions/runs/37622815846), job112797136062: completed Swift run 979 tests /157 suites with five issues: sameExactScopeMatches, scopeLessOnlyMatchesExplicitNoRequirements, exactTargetScopeMatches, onceMatchesOnlyItsFrozenCall, conversationGrantCanMatchLaterCallInSameExactScope. Conservative false versus required true; all other units and 20 XCTest passed | subsequently cancelled during UI; never GREEN |
| Scope GREEN | `57a8c718` / tree `54c2a412` | [37630609897](https://github.com/54zhien/Zen-Agent/actions/runs/37630609897), job112823653096: all 14 Scope functions and all 979 Swift tests /157 suites plus20 XCTest passed. Phone58 /one expected skip /three assertions in `PreviewHandoffUITests.testDeepReadingAnchorRestoresAfterNativeContentRemount` failed; actual Pad passed | failure; distinct S5-owned UI failure preserved |
| Evaluator pre-RED signature candidate | `df4ece2a` / tree `0afc7e5b` | [37638040685](https://github.com/54zhien/Zen-Agent/actions/runs/37638040685) superseded by explicit `return switch` correction; not behavioral evidence | cancelled; neither RED nor GREEN |
| Evaluator RED | `fe637c59` / tree `53de63f9` | [37638196089](https://github.com/54zhien/Zen-Agent/actions/runs/37638196089), job112850790372: compiled;20 new evaluator functions generated53 assertion issues, Swift999 /158 suites failed53 issues, all14 Scope and965 inherited Swift functions plus20 XCTest passed. Phone58 /one expected skip /zero failures; actual Pad passed | expected assertion failure |

Each observed unit run above had one actual Swift Testing run start. A cancelled
workflow is not passed; completed rule assertions before a later cancellation
are recorded as assertions only. No compiler failure is labeled behavioral RED.
The superseded candidate has no RED/GREEN claim.

Task2 GREEN candidate is `3fd4b758` / tree `46976fdf`, submitted to
[37643333096](https://github.com/54zhien/Zen-Agent/actions/runs/37643333096).
Its result and Task3 are not yet verified in this revision of the record.

## Rule boundary and future integration

The input is trusted, read-only authorization facts projected from the existing
ToolCall and immutable ToolExecutionIntent. It has no arguments JSON, executor
payload, alternate call state or storage. Descriptor metadata, actual resolved
resource/destination and the intent binding must come from trusted Runtime code,
not model arguments or the pane displaying approval.

One complete grant must cover the entire subject, action, revision and exact
source/destination; separate grants never combine into a source-to-sink permit.
The decision has stable reason codes. An allow result is a point-in-time
calculation, never a cached execution license.

Production dispatch, grant/policy persistence, OS consent/permissions, Files
Tool and Settings remain unimplemented here. No dependency, capability,
entitlement, signing or IPA change is part of S6-01. Future integration must
revalidate before the existing dispatch marker and preserve its crash semantics.

## Execution rulings

- PowerShell ledger/manual task briefs adapt the skill's Bash bookkeeping to this
  Windows checkout; cost: bookkeeping is manually maintained.
- S5-owned UI failures are preserved separately from completed Policy rule
  results; cost: these rule results do not establish a clean cumulative full gate.
- Completed unit assertion failures before later UI cancellation establish RED
  only; cost: they never establish a passed workflow or GREEN gate.

Stop after S6-01. No S6-02, PR merge, main push, automatic S5 absorption or IPA.

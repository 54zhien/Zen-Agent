# S6-02 — Action metadata and versioned frozen intent

Owner authorized continuation after S5 baseline sync on 2026-10-09.
This slice is not full Stage6 closure or physical-device acceptance.

## Baseline and ownership

- Own worktree: `C:/Users/Azusa/.codex/worktrees/8b9b/Zen-Agent`.
- Branch: `codex/s6-02-action-intent`, from clean combination N
  `de4a64f18f16530404c1890c74a494eff2e31e61`, tree
  `9a8fccd9293a07af4813df18383916f4aacba623`.
- Fixed S5 main M: `52a456bb53d10360aa6d485202f4bd05e2c6bdbf`, tree
  `3653f870c941368ff4fa4e6abc89e854a55cf2db`; parent2 of N.
- N's [full CI37924628504](https://github.com/54zhien/Zen-Agent/actions/runs/37924628504)
  success was checked live before continuation. This cannot substitute for S6-02 CI.
- Original S5 worktree remains separately owned. No edits to its checkout/index/HEAD.
- Blueprint pin `3b4b22c0df91be668406127c84c1822b359883c0`; development plan,
  CONTEXT, Tool Runtime and security notes read at that exact ref. Current Blueprint
  main remains older `99d30b8`; owner-approved supplement is retained.
- [Own implementation plan](../Docs/superpowers/plans/2026-10-09-s6-02-action-intent.md).

## Evidence in progress

| Candidate | Native result | Whole workflow |
| --- | --- | --- |
| `82e5ef6` | Superseded while native suite was starting; no completed assertions claimed | [37933226054](https://github.com/54zhien/Zen-Agent/actions/runs/37933226054) cancelled, neither RED nor GREEN |
| `fc29576` attempt1 | Compiled/native tests started; cancellation in the earlier RunEvent suite before either S6-02 suite. No RED | [37933543476](https://github.com/54zhien/Zen-Agent/actions/runs/37933543476) cancelled, never GREEN |
| `fc29576` attempt2, job113836899989 | Actual compiled Swift run:1058 tests /163 suites failed63 issues in129.689s. All63 are own S6-02 issues (continuation16, version/metadata47); inherited1041 and20 XCTest passed; one Swift run, zero host restart. Pending legacy executed/waited; target hook ignored; bad stored intents/arguments lacked original durable rejection; version/scope assertions failed. v1 terminal reuse positive control passed | Cancelled later in phone UI; actual assertion RED only, never a passed full gate. Actual Pad remains cancelled/not passed |

Windows static: YAML parses; all declared source paths exist; `git diff --check`
passes for this slice; scratch is ignored; existing branch profile returns `full`.
No local Swift build is claimed. Compiler failure, unfinished/cancelled/skipped
workflow is not a passed gate. Final commit/tree and exact-head CI go into the
conversation and external receipt to avoid a self-SHA loop.

RED attempt2 raw log SHA-256:
`d1d13846e080a11b81c0cb2b807407ea26b23e06a1894bb3115cd510acd1d636`.
Log retrieval's network retry is not a test rerun. Attempt2 is disclosed because
the first diagnostic was cancelled before the new suites executed.

Implementation emits v2 from all three real built-ins and adapts three existing
test-only executors with explicit metadata. Descriptor/schema/output semantics of
the built-ins remain revision1; v1 pending is rejected rather than upgraded. Codec
checks byte identities, declared action metadata, exact complete scopes, legacy
alias consistency and canonical object arguments. Scoped executors lacking a
trusted resolver fail closed; virtual test targets have explicit fixture resolvers.

The original ColdStart owner calls the existing AgentRuntime's validation before
rebuilding or waiting, so an old hidden approval cannot strand a Run. Undecodable
future/corrupt transcript data may still make continuation unrecoverable, but the
original pending call is first durably rejected and cannot execute. Known v1
terminal data remains decodable and its exact stored result is reused.

No DB migration is needed: existing intent TEXT, attempt, terminal rejected state
and ToolResult suffice. The new CAS transaction rejects only undispatched states
with the original attempt, inserts the matching result atomically and never
rewrites intent JSON. Direct invalid new arguments keep a non-executable transcript
representation on the original rejected row; this permits subsequent cold
continuation without inventing a new call or allow scope.

Added safety controls exercise stale-attempt rejection, dispatched/indeterminate/
terminal preservation and absent trusted scope resolver. At implementation
publication, the full native gate and fresh whole-slice review are pending. Their
observed outcome and exact final commit/tree are recorded after completion in
`C:/Users/Azusa/.codex/artifacts/s6-02-action-intent-20261009-8b9b/final-receipt.md`
and the final conversation handoff, never inferred from source or the RED run.

## Boundaries and carried issues

Reuse the same ToolExecutionIntent, Registry, ToolCall state and durable dispatch
marker. Freeze explicit descriptor Action and exact scopes in v2. v1 display and
terminal result reuse remain separate from execution permission; v1 pending cannot
be upgraded by filling allow defaults. Rejection stays on the original call.

Policy/grant storage and full pre-dispatch Policy/system-permission checking belong
to S6-03/04, Files/result guards to S6-05/06, Settings to S6-07. This step does not
claim those capabilities. No workflows/project/dependency/signing change or IPA.

S5 incoming Composer focus loss remains UNFIXED/deferred, including historical RED
37784846258/37801912044. Historical iPad first-Sidebar failure, physical acceptance,
SQLite teardown warnings and S6 aggregate-Equatable P3 remain disclosed. Current
intent validation must compare opaque identities as bytes and never rely on that
aggregate equality. No focus diagnostics or unchanged retry sweep here.

Stop after S6-02 native evidence and review. No S6-03, PR merge, main push or IPA.

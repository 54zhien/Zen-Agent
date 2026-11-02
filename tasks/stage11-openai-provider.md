# Stage 11 OpenAI Provider — implementation record

Status: implementation complete; CI-required baseline repair and protocol review fixes pending CI
Base: `4277ec0ba6ef27c67397b0532125ba3e836cf9be`
Branch: `codex/stage11-openai-provider`
Worktree: `C:\Users\Azusa\.codex\worktrees\stage11-openai\Zen-Agent`
Plan: [2026-11-02-stage11-openai-provider.md](../Docs/superpowers/plans/2026-11-02-stage11-openai-provider.md)

## Authority and scope

The Stage 11 plan and provider/model notes in `54zhien/Zen-Agent-Blueprint` authorize a second public model API to validate the existing provider boundary. Stage 10 code is present in the assigned base SHA; the lagging README stage text does not alter this slice.

Use only the paths authorized by the parent assignment. Do not edit Blueprint, schema/migration, project configuration, generated project files, or any other source/test path. The complete-source XcodeGen rules include additions below `App` and `Tests/ZenAgentTests` without a project change.

After CI on `84e61cb3ac782aeaf09ee64f050fa2cda58a9f52` showed that existing `SplitContainerUITests.swift:520` referenced an undeclared `editor`, the parent explicitly authorized a single binding in that test. The file was unchanged from `origin/main`; this is a CI-required baseline compile repair only, with no added test or assertion.

## Audited ownership and recovery

- `ConversationRuntime` owns Send preparation and freezes Provider ID, adapter revision, provider prompt instructions, and the existing full `RequestConfigSeed` before commit.
- `AgentRuntime` owns Run transitions, ToolPolicy/approval, tool dispatch, streaming projection boundaries, cancellation and recovery. The Provider only maps wire requests and outputs.
- `RunRequestRebuilder` reconstructs requests from the frozen snapshot. It must select the same Provider and reject unknown or changed adapters.
- `DelegationRuntime` owns Child identity and follows the parent's frozen model unless the persisted explicit target freezes its own provider/revision/seed.
- The registry is an immutable ID-to-adapter lookup. It has no runtime, factory, retry, or fallback policy.
- An unknown Provider, mismatch between the frozen Provider ID and the stored instance, or unsupported adapter revision fails explicitly and never falls back.
- OpenAI cancellation calls the existing HTTP stream cancellation path. OpenAI requests are not replayed by the adapter; partial-output error semantics stay in `ProviderError`.

## Official OpenAI protocol evidence

First-party docs checked on 2026-11-02: [GPT-6.1 Terra](https://developers.openai.com/api/docs/models/gpt-6.1-terra), [Responses streaming](https://developers.openai.com/api/docs/guides/streaming-responses), [function calling](https://developers.openai.com/api/docs/guides/function-calling), [create response](https://developers.openai.com/api/reference/resources/responses/methods/create), [streaming events](https://developers.openai.com/api/reference/resources/responses/streaming-events), and [reasoning](https://developers.openai.com/api/docs/guides/reasoning).

Choice: `gpt-6.1-terra` using Responses, `reasoning.effort=none`, and `store=false`; advertise text, streaming, and function tools only. This avoids losing opaque reasoning protocol state in the current stateless chat/tool transcript. Calls use Responses semantic events and each result preserves the original `call_id`.

## Implementation ledger

- [x] Added registry lookup and frozen adapter identity contract tests; immutable exact-ID/revision routing is implemented.
- [x] Added OpenAI request/descriptor contract tests; Responses request and provider adapter are implemented.
- [x] Added OpenAI semantic streaming tests for terminal completion, parallel function calls, interruption and cancellation; stream decoder and transport cancellation are implemented.
- [x] Runtime and Settings route new Sends by instance Provider, recovery by the frozen Run snapshot, and explicit Child targets by their frozen Provider binding.
- [x] Added the parent-authorized `editor` query binding to the existing bottom-drop UI test to repair the CI baseline compile error; no test behavior or assertion was added.
- [x] Runtime validates the persisted instance Provider against the frozen Run Provider before marking a fresh provider dispatch started; refusal completion events are ignored through `response.completed`. Focused contracts cover both behaviors.
- [x] Local static checks are recorded below; implementation is ready for branch delivery and CI.
- [x] Committed and pushed the CI baseline repair on `codex/stage11-openai-provider`; draft PR [#58](https://github.com/54zhien/Zen-Agent/pull/58) remains open.
- [ ] Commit/push the protocol review fixes, verify the remote SHA, and record the latest CI result.

## Verification

Windows has no Swift/Xcode toolchain per repository instructions. Local native build and XCTest cannot be claimed; full build/test evidence must come from CI.

Local static results before commit:

- `swiftc -frontend -parse` on all 22 branch-changed Swift files: PASS (syntax parsing only).
- `python -c "import yaml; yaml.safe_load(open('project.yml', encoding='utf-8'))"`: PASS.
- `git diff --check`: PASS.
- All 24 branch-changed/uncommitted paths checked for CRLF: PASS (LF only).
- XcodeGen source configuration includes `App` and `Tests/ZenAgentTests`; no project edit is needed.
- `git check-ignore -v ZenAgent.xcodeproj/project.pbxproj`: PASS (`*.xcodeproj/`).
- `xcodegen generate`: unavailable; PowerShell reported that `xcodegen` is not recognized.
- Native build and XCTest: not run locally; await CI.
- CI run `41481266193` on `84e61cb...` passed `Build app` but failed the UI test target compile at `Tests/ZenAgentUITests/SplitContainerUITests.swift:520` with `cannot find 'editor' in scope`. The parent-authorized binding above addresses that baseline issue; the resulting SHA's CI is pending.

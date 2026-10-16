# S6-02 — Action metadata and versioned frozen intent

Owner requested continuation on 2026-10-09. Execute S6-02 on the existing isolated
worktree, new branch `codex/s6-02-action-intent`, fixed base combination N
`de4a64f18f16530404c1890c74a494eff2e31e61` (tree
`9a8fccd9293a07af4813df18383916f4aacba623`). N contains verified S5 M
`52a456bb53d10360aa6d485202f4bd05e2c6bdbf`; full CI37924628504 is success.

Spec: Blueprint `3b4b22c0df91be668406127c84c1822b359883c0`, development plan,
CONTEXT, Tool Runtime and security notes. Existing Stage6 plan section7 S6-02
defines scope. Original Desktop attachment is absent; its committed copy is used.

## Design and ownership

Extend the existing Descriptor with explicit S6-01 action metadata, and the same
Intent with optional Codable fields for frozen action/resource/destination.
Emit v2 for new calls. Decode v1 for historical display/terminal result reuse,
but reject every old pending v1 on its original ID before execution. No default
allow scope, reparsing upgrade, parallel registry, new executable payload or
second call state. Unknown versions and malformed JSON also fail safely.

The executor's prepare resolves the action and exact scopes. Runtime checks the
same immutable value at creation and before the existing durable dispatch marker.
Metadata comparison uses explicit byte identity comparisons, not aggregate
Equatable. Trusted executor dependency validation can reject changed targets;
it cannot substitute a new intent. This is structural/semantic validation,
not the full Policy/grant/system permission integration reserved for S6-04.

Validation failures persist stable results. A conditional transaction settles
only an undispatched original call plus its result, checking attempt. No JSON
rewrite/DB schema change is needed; review confirms the existing intent TEXT
column and terminal states suffice. Waiting recovery validates before waiting.
Historical continuation accepts v1 transcript representation without granting
permission to dispatch it. Invalid new arguments produce a rejected original
call/result so the remaining batch continues.

Allowed production: ToolRegistry, new ToolIntentCodec, ToolRuntime, three existing
built-ins, Policy type Codable conformances, PersistenceStore+ToolCalls,
AgentRuntime, RunRequestRebuilder and the original ConversationRuntime cold recovery
handoff. Tests: new ToolIntentVersionTests and
ToolIntentContinuationTests, existing three ToolExecutable fixture definitions.
Own plan and `tasks/s6-02-action-intent.md`. All other S5 UI/Workspace/AppShell,
Settings/Files, signing/Config/workflows/project/dependencies stay untouched.

## Execution

1. Compile-safe unused signatures plus behavioral tests: metadata/v2 roundtrip,
v1 display, pending v1/unknown/corrupt/changed descriptor rejection on same call,
target/dependency change, missing metadata/scope, Unicode identity, terminal result
reuse and invalid-then-valid native provider continuation. Push and observe actual
assertion RED; compiler failures never count.
2. Implement metadata, codec and trusted dependency validation; explicit fixture
metadata preserves inherited contracts. Add CAS settlement using existing schema.
Integrate creation/recovery rejection and historical representation. Full CI.
3. One fresh whole-slice review; Important/Critical findings get one test-first fix
pass. Record actual exact-head native CI and stop. No S6-03, main push, PR merge,
IPA or S5 focus diagnostic retry sweep.

Known focus loss remains UNFIXED/deferred; device, historical iPad Sidebar and
SQLite warnings remain open. Existing S6 aggregate Equatable P3 is not used as
authorization identity. Failed/cancelled/running CI is not passed.

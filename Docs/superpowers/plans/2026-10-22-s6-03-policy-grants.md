# S6-03 Policy and scoped grant persistence implementation plan

> Execute inline with superpowers:executing-plans and test-driven-development; review with requesting-code-review before completion.

**Goal:** Persist existing Policy/Grant domain values with transactional revocation and lifecycle invalidation, without changing UI or wiring new execution authority.

**Architecture:** Reuse ZenDatabase/PersistenceStore and the single S6-01 evaluator. Add v14 tables for logical global action policy and immutable scoped grant issuance; mutable validity is one column, never a second authority. Existing original ToolCall/Run/Conversation remain the lifecycle sources. SQLite transactions and triggers invalidate grants atomically with their owning state transitions, rather than adding new Runtime callbacks.

**Spec:** Existing approved Stage6 roadmap, 2026-10-07-stage6-policy-foundation.md section7/S6-03. Blueprint pin fffca086f4451a7bd0988959058ddcfe5eb6c13d: development plan, CONTEXT, Tool Runtime blob9d961dc500d8b39bf1623e568becf347cf5239c7, security blob79d8b5355466d7fad47c673416e7c4c5c0105b12. The latter two are unchanged from S6-02's approved spec.

**Baseline:** main f12cb87be247cd3cd5cf54743bdeea68f92a8e50; native full CI38847153473 success verified live. Managed worktree s6-03-policy-grants. UI integration PR37 remains draft/unmerged and its diagnostics are parked/restored at78b67c2. Owner explicitly authorized Stage6 continuation on2026-10-22 despite that parked issue. No UI files, Config, Resources, project.yml, workflow, signing, IPA, Stage7+ work.

## Storage contract

- Policy identity is byte-exact tool/action, with explicit descriptor revision. Missing policy is askEveryTime, epoch0. Policy reads preserve a stored different revision for evaluator rejection. Widening cannot lower epochs. Tightening or revision change increments a checked Int64-backed epoch and invalidates active grants for that logical action in the same write.
- Grant rows have a unique stable issuance ID, original subject/tool/action/revision/resource/destination, kind and approval witness; no upsert/revival. Scope JSON uses existing Codable domain scopes, rejects unknown/malformed values. No arguments, credentials or raw intent copies in grant storage. Opaque intent binding is supplied by trusted caller; S6-04 must define/prove its derivation and dispatch serialization, not inferred here.
- Issuance validates a current expected Policy snapshot, non-deny policy, complete exact scopes, active validity, matching epoch, original pending ToolCall and live Run/Conversation subject. Parent subject requires the original parent Run in that Conversation; a Run subject must match the originating Run. A once binding must match its approval witness. Issuance is not a new approval UI/API or automatic execution path; evaluator/action constraints remain mandatory in S6-04.
- Revocation is one-way. Terminal or indeterminate original call consumes its once grant; terminal/deleted Run revokes Run-subject grants and consumes once grants; nonvisible/deleted Conversation revokes its subjects and origin grants, and Undo does not revive them. Parent-conversation grant survives completion of an individual Run.
- SQLite BINARY identity and explicit domain byte equality preserve composed/decomposed Unicode identities. Unknown/corrupt persisted authority fails closed, never defaults to allow. No data-import trust restoration is added.

## Tasks

- [x] Add compile-safe unused storage signatures and native tests for roundtrip/reopen/migration, scope isolation, duplicate issuance, stale snapshot, policy tighten/widen, explicit revoke, original lifecycle terminal/Undo, malformed storage, byte identity and concurrent tighten/issue. Push once and obtain actual native behavioral RED; compile failure is not RED.
- [ ] Implement v14 migration, separate Policy and Grant persistence extensions and row conversion. Use transactional lifecycle triggers for original owners. Run static checks, push and obtain actual XcodeGen/build/unit/UI gate result. Preserve inherited failures separately; no unchanged rerun to wash GREEN.
- [ ] Fresh review of whole slice; fix real findings with focused tests and native evidence. Record exact source/run/digest. No PR merge or Stage6 aggregate closure without actual evidence; no S6-04 UI work without examining impact first.

Files: App/Persistence/Migrations.swift; new Migrations+ToolPolicy.swift, PersistenceStore+ToolPolicy.swift, PersistenceStore+ToolGrants.swift and ToolGrantRecord.swift; new Tests/ZenAgentTests/ToolPolicyPersistenceTests.swift and ToolGrantPersistenceTests.swift (shared fixture in latter); this plan and tasks/s6-03-policy-grants.md. No other production boundary changes.


Ruling after source/security review: match the existing ConversationRuntime approval boundary: grant issuance only accepts an original root Parent Run (kind parent and parentRunID nil), for both grant kinds and both subjects. Child-origin grants stay unavailable until the later Subagent stage implements ancestor validity/expiry. Existing ToolApprovalUITests already excludes Child calls. No recursive child lifecycle scaffolding in S6-03. Added parameterized negative test covers actual Child origin attempting its own Run, Parent Run and Parent Conversation subjects; storage never trusts the display subject alone. These extra negative controls are prepared before implementation, outside the already-running12-function RED source.


Correction to cancellation inference: source1611e65/run39754034808 was cancelled too early to establish RED. Main's20XCTest passed, then Swift Testing started09:28:26; the captured log has zero S6-03 case starts/issues and no completed Swift summary, zero Phone UI starts. Pad1/1 did pass. Main spent substantially longer compiling than Pad; Pad timing is not evidence that main had finished units. Preserve this incomplete run, never call it behavioral RED or full GREEN. Raw logs retained.

Ruling: add a temporary manual s6_contract_red selector to the existing workflow, running only the two new native suites and omitting the independent Pad job only for this RED profile. This is a source/test-selection change justified by the missing target execution, not an unchanged rerun. No production behavior changes; stubs remain. Let this targeted job complete, no timing-based cancellation. Remove every workflow/profile change byte-for-byte to1611e65 before implementation's clean full CI. The prior full-suite plan is superseded only for RED evidence acquisition; final full gate is unchanged.


Implementation ruling: grant subject-list reads retain named issuance IDs alongside the existing ToolScopedGrant values, so recovery can revoke the original row without deriving an ID from displayed scope. This is a storage address, not a second Policy model; there are no existing production callers to migrate. The reopen test verifies the ID/value projection. Added both call-terminal-first and run-terminal-first variants to the existing lifecycle contract before implementation verification. No per-variant RED is claimed beyond the observed13-function/20issue source.

v14 implementation prepared: separate Policy/Grant tables and lifecycle triggers; original root Parent Run validated in the issuing transaction; immutable scope/version/endpoint and expected Policy floor; no upsert/revival; strict scope decoding. Workflow restored to main, no temporary selector retained. UI/Runtime/Config/Resources/project.yml unchanged. Static/native final verification pending.


Final review ruling: one P2 (implicit default revision anchoring) reproduced at1e42937/run39759333708:14tests,2issues only in new regression; original13passed. One fix pass anchors the effective snapshot in the existing issuance transaction after all guards. Actual narrow fix re-reviewed without directly related Important/Critical findings. Full final native gate and merge receipt live on the S6-03 PR; no post-verification source edits just to record run IDs. See tasks/s6-03-policy-grants.md for preserved failures and boundaries.

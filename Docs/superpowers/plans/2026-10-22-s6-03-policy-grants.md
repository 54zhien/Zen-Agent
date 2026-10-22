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

- [ ] Add compile-safe unused storage signatures and native tests for roundtrip/reopen/migration, scope isolation, duplicate issuance, stale snapshot, policy tighten/widen, explicit revoke, original lifecycle terminal/Undo, malformed storage, byte identity and concurrent tighten/issue. Push once and obtain actual native behavioral RED; compile failure is not RED.
- [ ] Implement v14 migration, separate Policy and Grant persistence extensions and row conversion. Use transactional lifecycle triggers for original owners. Run static checks, push and obtain actual XcodeGen/build/unit/UI gate result. Preserve inherited failures separately; no unchanged rerun to wash GREEN.
- [ ] Fresh review of whole slice; fix real findings with focused tests and native evidence. Record exact source/run/digest. No PR merge or Stage6 aggregate closure without actual evidence; no S6-04 UI work without examining impact first.

Files: App/Persistence/Migrations.swift; new Migrations+ToolPolicy.swift, PersistenceStore+ToolPolicy.swift, PersistenceStore+ToolGrants.swift and ToolGrantRecord.swift; new Tests/ZenAgentTests/ToolPolicyPersistenceTests.swift and ToolGrantPersistenceTests.swift (shared fixture in latter); this plan and tasks/s6-03-policy-grants.md. No other production boundary changes.


Ruling after source/security review: match the existing ConversationRuntime approval boundary: grant issuance only accepts an original root Parent Run (kind parent and parentRunID nil), for both grant kinds and both subjects. Child-origin grants stay unavailable until the later Subagent stage implements ancestor validity/expiry. Existing ToolApprovalUITests already excludes Child calls. No recursive child lifecycle scaffolding in S6-03. Added parameterized negative test covers actual Child origin attempting its own Run, Parent Run and Parent Conversation subjects; storage never trusts the display subject alone. These extra negative controls are prepared before implementation, outside the already-running12-function RED source.

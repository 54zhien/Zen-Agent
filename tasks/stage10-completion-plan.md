# Stage 10 Completion Plan

> **For agentic workers:** Implement the slices in order. Each slice ends with the relevant existing behavior tests and a full native PR gate before the next slice is treated as complete.

**Goal:** Finish the implementable Stage 10 Subagent behavior after PR #47, while keeping concurrency defaults and user configuration behind the Blueprint's real performance and Provider-limit evidence gates.

**Architecture:** Reuse the persisted Parent/Child Run, stable delegation ToolCall, `DelegationRuntime`, `AgentRuntime`, `ToolRuntime`, and shared `ToolPolicy`. Keep approval projection in its existing Runtime/UI boundary; Child execution and its selected context remain owned by the delegation Runtime. The persistence owner validates frozen references and Child grant identity transactionally.

**Tech Stack:** Swift, SwiftUI, GRDB, existing Swift Testing/XCTest suites, XcodeGen and the repository's native GitHub Actions gate.

**Spec:** Blueprint PR #9 HEAD `f8861dd9c98a416cdf80ab1ccb8d576a183a6ee2`; `Design/Zen Agent 开发规划.md` Stage 10, items 5–9 and gate; `Design/Zen Agent Agent 能力与扩展.md` §§3, 5, 7–10; `Design/Zen Agent Tool Runtime.md`; `Design/Zen Agent Prompt、Soul 与 Memory.md` Memory selection and snapshot rules.

## Starting Point

- PR #47 source `cee3bdf2c74655b565ee71393feb6d0f0272d7f5` passed exact-head native run `40990023248`; documentation receipt `e600e96fb14b5a033901aac7f1b443646eb9073e` is the parent of this branch.
- Stage 10 items 1–4 have a persisted delegation revision, one Child result path, stable Parent/Child persistence, and Stop/recovery reconciliation. The existing frozen policy defaults to disabled, depth 1, one active Child, Follow Parent, and an empty Environment mapping.
- Stage 10 items 5–7 remain: Child Tool Approval, Child Memory/Skill/Environment subset, and dual Child execution/validation.
- Stage 10 items 8–9 remain gated: Provider throttling, cancellation propagation, and real-device performance/cost evidence must precede choosing and exposing concurrency defaults or user settings.

## Current Implementation Status

- This branch is implementing Blueprint items 5–6 as one single-Child vertical gate because Child approval, frozen subset creation, Parent Stop, and Child recovery share the same persisted call lifecycle. The work is not yet compiled or natively tested; only Windows `swiftc -parse` and `git diff --check` have run.
- Child tool approval uses the existing `ToolPolicy` path with Child Run subject and `.once`; cold recovery rebinds the Child's frozen filtered registry, reuses its original ToolCall batch and continuation, and confirms the original Parent delegation call only after a terminal Child result is durable.
- The Subagent call may explicitly name `environmentKeys`; the arguments are normalized by key (model array order has no authority), the approval disclosure names only requested keys, and the Child Skill subset includes a Skill only when its complete frozen Environment references are requested. No Secret values are copied.
- A Child checkpoint with an incomplete committed tool-call transcript is terminalized through the existing taskless settlement transaction as `.unrecoverable`; the original Parent call receives the actual terminal Child report. No ToolCall or Provider request is fabricated or replayed.
- The cold approval approve/reject/Parent Stop behavior tests are present but have not run on the native CI gate. Do not treat static parsing, review, skipped tests, or a cancelled run as a pass.
- Slice 3 (fixed hidden two-Child validation) is not started and is blocked on a successful exact-head single-Child gate. Stage 10 concurrency measurement and settings remain open after that validation; this branch does not claim the external evidence gate.

## Global Constraints

- The Parent Run's frozen `exposedTools` and frozen context references are the upper bounds for any Child. Runtime state or current Settings cannot widen them.
- Child tools exclude recursive Subagent, MCP tools without an independently frozen Child binding, and Environment-dependent tools whose references were not selected into that Child.
- Every Child approval is owned by the linked Child Run and can grant only that exact call once. Parent Conversation grants never authorize Child calls; Child grants never authorize later calls or the Parent.
- Child Memory and Skill candidates come only from the Parent Run's exact frozen revision references; reuse the existing Memory Retriever and Skill Router against the Child task, then freeze only selected identities in the Child snapshot.
- Environment values default to none. An explicit Child subset may contain only exact same-key references already frozen by the Parent/activated Skill; retain revision and opaque credential identities, copy no Secret values, add no rename or precedence rules, and let explicit deletion/revocation/security tightening invalidate dependent Runs.
- Keep Child prompt/history outside Parent Conversation history and Timeline. Return each Child result only through its original stable Parent ToolCall.
- Keep the current product default at one active Child and do not add user concurrency settings in these slices. A fixed two-Child parallel probe is validation only after the single-Child cancellation, approval, and recovery gates pass; it is not a product default or a performance/cost claim.
- Do not change approved card geometry, animation, or text layout. Add only the Blueprint-required Subagent source indication and Child-specific authorization subject.
- Do not add defensive-only code or tests, modify CI workflow/skip/budget settings, merge PRs, or claim physical-device acceptance without measurements on the target device.

## Review Focus

- A Child never receives a tool or context reference outside the Parent's frozen snapshot; test a later registry/configuration change while a Parent is active.
- A Child approval is attached to the Child Run, cannot consume a Parent grant, and cannot create a conversation grant; test approve-once and reject through the existing approval flow.
- Parent Stop and cold recovery preserve known Child results and settle any active/approval-waiting Child without duplicate execution or a dangling Parent ToolCall.
- Memory, Skill, and Environment selection is a subset of the exact Parent frozen references, and no Secret value enters a prompt, log, or ordinary result.
- The post-gate dual-Child probe reaches two active Child Runs only under its fixed validation policy, then persists both results to their original calls and cancels both on Parent Stop.

---

### Slice 1: Single-Child Approval, Frozen Subsets, and Recovery (Blueprint Items 5–6)

**Files owned by the Runtime/Tool/UI implementer:**

- Modify `App/Runtime/DelegationRuntime.swift` to form the Child's tool surface from the Parent's frozen descriptors and the already resolved executor context. Freeze only descriptors present in `parentSnapshot.exposedTools`; exclude `SubagentDelegationTool`, MCP tools without a Child MCP binding, and tools whose Environment requirements are not bound in the Child snapshot. Bind this filtered registry to the Child Run and pass its Provider tool definitions into the Child request.
- Modify `App/Runtime/ConversationRuntime.swift` only at the existing approval projection/decision boundary: include linked Child calls in the owning Conversation's pending approval list and route decisions to the same `AgentRuntime` call owner.
- Modify `App/Runtime/ToolApprovalProjection.swift` and `App/Conversation/ToolApprovalCardView.swift` to carry and display a `.subagent` source and Child Run authorization description. Keep existing geometry, animation, and decision order; Child cards expose only approve-once/reject-once.
- Modify `App/Runtime/AgentRuntime.swift`, `App/Runtime/RunRecovery.swift`, `App/Runtime/RunRequestRebuilder.swift`, and `App/Tool/ToolRuntime.swift` so Parent recovery hands the original delegated ToolCall to the Child checkpoint owner. Recover the Child with its own frozen snapshot and bound registry; preserve an approval-waiting Child ToolCall and resume its committed batch after the Child decision. A terminal Child result confirms the same Parent ToolCall; an unknown Provider attempt is not replayed.
- Modify `Tests/ZenAgentTests/Stage10DelegationRuntimeTests.swift` and `Tests/ZenAgentTests/ToolApprovalUITests.swift` for a Child tool dispatched under its own Run, the frozen Parent tool ceiling, a Subagent source card, parent-grant non-inheritance, one-call approval, rejection, and Parent Stop/recovery of an approval-waiting Child.

**Persistence owner, after the root assigns files:**

- Modify `App/Persistence/PersistenceStore+ToolAuthorization.swift` to derive Parent calls as `.parentConversation(conversationID)` and linked Child calls as `.run(childRunID)`; load grants only for that exact subject. Permit only `.once` for a Child even when its descriptor supports conversation grants. Validate the Child↔Parent link and the still-active Parent/Child lifecycle in the existing transaction.
- Reuse `ToolGrantRecord`'s existing `.run` subject and `.once` grant representation; no parallel authorization mechanism or schema change is planned unless the current transaction proves insufficient.

**Dependency:** PR #47's stable Parent ToolCall→Child Run relation, Child execution snapshot, existing `ToolPolicy`, `ToolRuntime.approveToolCall`, and Parent cancellation/recovery paths.

**Acceptance:** Existing approval presentation remains unchanged apart from Subagent source/Child ownership; the Child's tool call is visible in the owning Conversation, approved on that same call under the Child Run subject, and its terminal result is returned through the original delegation ToolCall. Cold recovery of a pending Child approval must approve, reject, or stop the same persisted Child call without replaying its Provider request; Parent Stop and incomplete committed Child input must leave no active Child or unresolved Parent delegation call.

### Slice 2: (Combined into Slice 1) Frozen Memory, Skill, and Environment Subsets

**Files owned by the Runtime/Tool implementer:**

- Modify `App/Runtime/DelegationRuntime.swift` to derive the Child candidate pool solely from the Parent snapshot's exact `memoryReferences`, `skillReferences`, and Environment references. Use `MemoryRetriever` and `SkillRouter` with the Child task, constrained to those frozen candidates; store only the selected Child identities/revisions in the Child snapshot.
- Resolve the selected frozen Memory/Skill context while building the Child request through the existing `MemoryRuntime`, `SkillRuntime`, `EnvironmentRuntime`, and `PromptComposer` paths. Do not copy Parent history, all Parent context, current Settings, or current Memory/Skill inventory into the Child.
- Extend `App/Runtime/RunExecutionSnapshot.swift` or the existing snapshot codec only if a specific frozen Child mapping identity cannot be represented with existing reference types; any new field must remain content-free and preserve old format decoding.

**Persistence owner, after the root assigns files:**

- Update `App/Persistence/PersistenceStore+Delegation.swift` Child snapshot validation to enforce only selected references that are present in the Parent snapshot and selected tool descriptors within the Parent frozen exposure ceiling.
- Add an Environment resolver read only if the existing resolver cannot resolve the selected frozen reference identity at execution time. Never copy a Secret value into a Run row, prompt, or Tool result.

**Tests:** Extend `Stage10DelegationRuntimeTests.swift`; reuse `MemorySnapshotTests.swift`, `MemoryRetrievalTests.swift`, `SkillSnapshotTests.swift`, `SkillEnvironmentTests.swift`, and `EnvironmentSecretHandoffTests.swift` for their owning semantics. Prove a selected Child subset stays on the Parent's old revisions after mutable settings/revisions change; prove deletion/revocation invalidates rather than falls back to current values.

**Dependency:** Slice 1 Child execution/approval path and PR #47's parent snapshot resolver. Environment mapping remains empty unless a per-call explicit subset points to an exact Parent-frozen same-key reference.

**Acceptance:** Child prompt and executor bindings contain only task-relevant, Parent-frozen Memory/Skill/Environment references; unselected references and unbound MCP/Environment tools are absent. Slice 2 is reviewed and gated with Slice 1 because the Parent ToolCall intent and the Child snapshot are frozen atomically during the same delegated Child creation transaction.

### Slice 3: Dual-Child Validation

**Files owned by the Runtime/Tool implementer:**

- Modify `App/Runtime/AgentRuntime.swift` to dispatch a provider batch of independent Subagent calls concurrently while preserving each ToolCall identity, existing ToolPolicy admission/dispatch boundary, ordinary tool ordering, and the Parent's result order. Keep this focused on Subagent calls; do not parallelize unrelated Tools.
- Modify `App/Runtime/DelegationRuntime.swift` to permit two active Child Runs only when the Parent's frozen validation policy permits the two-Child probe, and to collect/cancel each Child by its stable identity.
- Keep the persisted product default at one active Child. Any fixed two-Child probe must remain unexposed to Settings until Provider and device measurements authorize a production default/limit.

**Persistence owner, after the root assigns files:**

- Modify `App/Persistence/PersistenceStore+Delegation.swift` and `App/Persistence/Migrations+Delegation.swift` only if transactional active-Child counting must change from the existing one-active-child index; preserve an atomic per-Parent bound supplied by the frozen Parent policy.

**Tests:** Add a real batch test that observes two active Child IDs before either result completes, verifies both results settle to their original ToolCalls in batch order, and verifies Parent Stop cancels both without losing known results. Re-run single-Child approval/recovery/Stop tests unchanged.

**Dependency:** Slice 1 passes Child authorization/approval/cancellation/recovery gates; Slice 2 freezes each Child's tool and context subset. No user-configured concurrency field is introduced.

**Acceptance:** The fixed two-Child validation path proves dual-result persistence and cancellation propagation; the product default remains one active Child.

### Slice 4: Provider and Device Concurrency Gate (External Evidence)

- Gather actual integration evidence for provider rate limits, cancellation propagation, and cost/performance with the target iPhone/iPad and configured Provider. Native CI may verify deterministic runtime correctness but cannot substitute for these measurements.
- Record measured inputs and outcomes in the Stage 10 receipt. Only after those results exist may the product owner select concurrency defaults/upper bounds and approve the final `Settings → Agent → 子代理` concurrency control. No UI or numeric default is chosen by this plan.
- Do not mark Stage 10 fully closed while this external gate remains unmeasured. Report the exact missing device/provider evidence and preserve the implemented single-Child default.

## Worktree and Branch

- Worktree: `C:\Users\Azusa\.codex\worktrees\stage10-completion\Zen-Agent`
- Branch: `codex/stage10-completion`
- Base: PR #47 receipt head `e600e96fb14b5a033901aac7f1b443646eb9073e` (tested source parent `cee3bdf2c74655b565ee71393feb6d0f0272d7f5`).
- PR base when the work is ready: `codex/stage10-delegation-snapshot`; do not merge.

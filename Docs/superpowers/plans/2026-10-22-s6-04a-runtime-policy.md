# S6-04a Runtime Policy integration implementation plan

> Execute inline with superpowers:executing-plans and test-driven-development; one fresh whole-slice review at the end.

**Goal:** Connect the existing Policy evaluator and durable grants to ordinary, approved and recovered ToolCall dispatch, with no accepted View/layout/animation changes.

**Architecture:** Reuse original ToolCall/ToolResult/Run identities. Persist immutable admission facts alongside a ToolCall in v15; record typed ToolCall failure semantics, not new Run EndReasons. Evaluate using the single S6-01 kernel inside the same SQLite write that commits dispatch. The Runtime resolves/validates the frozen intent synchronously immediately before that transaction and executes the identical payload only after commit. Explicit approval issues a once grant and updates the original waiting call atomically using the existing S6-03 issuance rules.

**Spec:** Blueprint fffca086f4451a7bd0988959058ddcfe5eb6c13d, Design/CONTEXT.md, development plan Stage6, Tool Runtime sections4-7 and security sections4-5; approved repository roadmap 2026-10-07-stage6-policy-foundation.md section7/S6-04. Tool Runtime/security blob identities unchanged from S6-03.

**Baseline:** main1fd98c6572553d257120d99b1f7eabb9c859448a, tree5c5d681bbbfd3000f11c1f29f2a6ad01a52882e2. Identical source tree passed full native39761453960; post-merge main39769209066 is still running at plan publication, not assumed passed. PR38 merged. Original UI PR37 stays parked/unmerged. Reuse the chat-owned isolated worktree on new branch codex/s6-04-runtime-policy-20261022.

## Constraints and ownership

- Owner said continue after the reported S6-04 approval impact. Start with the smallest backend integration slice; the prior UI freeze still applies outside specifically reported Tool approval changes. No accepted Views, Composer, Workspace gestures, Sidebar, Config, Resources, project.yml, dependencies, signing or IPA changes in this slice.
- Persistent default is askEveryTime, not legacy automatic execution. Tests intending automatic execution must explicitly configure alwaysAllow; never add a production test-mode bypass.
- Admission captures original action/revision/mode/epoch/disposition and a trusted SHA256 binding over exact frozen JSON. No second executable payload. Waiting/missing legacy admission cannot be upgraded by Settings widening; explicit approval remains possible only on the original eligible call.
- Hard/unknown Cap and deny are authoritative at creation, approval and dispatch. The Runtime's trusted cap is immutable configuration; map the existing required-approval descriptor into that cap. No invented mutable RunPolicy or Settings layer. Current global policy/grant tightening is serialized by SQLite; no async gap before the conditional dispatched write.
- Scope for root Parent origin matches S6-03. Child-grant support remains unavailable until the later Subagent stage. Once grants bind the exact call/run/intent even with the root Parent Conversation principal.
- Existing validateDependencies is a synchronous trusted check, never a target rewriter. Descriptor/frozen target changes reject the original undispatched call. OS permission is not implemented or simulated as authorized here.
- Preserve dispatched-before-executor, original attempt CAS, notExecuted/indeterminate and no blind replay. Persist policyDenied/dependencyChanged/reapprovalNeeded/outcomeUnknown on the original ToolCall; preserve original intent error result text for existing S6-02 compatibility.
- S6-04b owns independent system permission consent/request state and scope-choice UI. This slice does not close all of S6-04, expose Files or Settings, or claim physical-device acceptance.

## Files

- App/Tool/ToolRuntime.swift: adapt existing admission/approval/dispatch boundaries; unused cap input only before RED.
- New App/Tool/ToolIntentBinding.swift: trusted binding over exact frozen JSON; never synthesize or rewrite approval disclosures.
- App/Persistence/Records.swift: optional typed ToolCall failure reason, preserving old initializers/records.
- App/Persistence/Migrations.swift + new Migrations+ToolAuthorization.swift: v15 call admission facts and nullable failure reason.
- New App/Persistence/ToolCallPolicyRecord.swift: strict durable projection of existing policy/admission values.
- New App/Persistence/PersistenceStore+ToolAuthorization.swift: transactional creation, explicit once approval and guarded dispatch using the one evaluator.
- App/Persistence/PersistenceStore+ToolGrants.swift: extract existing issuance core for reuse in an enclosing write; no new grant semantics.
- App/Persistence/PersistenceStore+ToolCalls.swift: typed durable rejection/unknown outcome, preserving original ownership/CAS.
- App/Runtime/AgentRuntime.swift: repeat the existing decision wait when dispatch legitimately returns to approval; both live and recovered batches retain original identity/continuation.
- Tests/ZenAgentTests/ToolRuntimePolicyTests.swift: new runtime contracts; existing runtime/continuation fixtures only where automatic policy or durable admission must become explicit.
- This plan and tasks/s6-04a-runtime-policy.md; temporary CI RED selector only during native RED, fully restored for final gate.

## Review focus

1. An old approved/prepared row without admission must not inherit today's wider policy. Test explicit reapproval on original identity and no executor entry.
2. Policy/grant revocation after approval or dependency validation must beat dispatch. Test exact grant ID revocation and a deterministic validation-hook tightening.
3. Two callers/stale attempts must not share one dispatch. Test parallel dispatch and a changed attempt before checkpoint.
4. A terminal/hidden subject or new Runtime with a hard cap must prevent an old grant. Test actual subject lifecycle and stricter trusted Runtime configuration.
5. Rejecting/reapproving one call must preserve batch continuation and original durable results. Adapt live/recovered loop tests using actual emitted requests, no reconstructed expectation-only pipeline.

## Tasks

- [x] Add black-box runtime contracts against existing APIs plus an unused default cap argument. Static parse/check; commit/push and run a disclosed focused native RED suite to completion. No production Policy behavior before observed assertions.
- [ ] Implement admission/approval/guarded dispatch and typed original-call failures. Adapt only fixtures that intentionally require automatic policy or valid recovery admission; keep security regressions. Static checks, one normal complete native generation/build/unit/Phone UI/Pad gate.
- [ ] Fresh whole-slice review, one test-first Important/Critical fix pass if needed, exact-head final receipt and integration only after real complete gate. Preserve every failed/cancelled/skipped provenance; never rerun unchanged to wash a failure.

Final native source/run/tree/review and merge receipt belong on the PR/external receipt, avoiding source edits merely to record the CI run. Existing authorization to continue the approved roadmap is carried forward; no repeated design or execution permission is requested for this narrower slice.

Ruling after actual code inspection: missing complete frozen disclosure must reject explicitly rather than create an invisible waiting card. Do not invent UI prose or rewrite a persisted intent. Synthetic old functional fixtures will declare complete trusted disclosures; real built-in disclosure/consent interaction remains S6-04b before tool exposure. Added four focused controls (high risk, absent disclosure, stop before checkpoint, corrupt grant) before implementation; the already-dispatched immutable RED source has17 functions, so no individual native RED is claimed for these extra controls.

Additional boundary discovered before implementation: legacy manually persisted waiting calls lack admission, so the explicit Approval request must carry the hash of the exact JSON displayed. Add a data-only witness field through ToolApprovalProjection/Request, ConversationRuntime and AgentRuntime to ToolRuntime approval. A stale card rejects the original call, never authorizes a replacement target. Add a black-box legacy-card mutation test using existing UI-request APIs. No View file/layout/animation changes; this closes the existing approval boundary rather than adding scope-choice UI.

Implementation source ready for one fresh whole-slice review before the final full native gate, avoiding invalidating a running final gate for predictable review fixes. Extra real-flow controls cover v14 upgrade without invented admission, deny + allowed batch continuation, revoked approval returning to the original waiter, and disk cold prepared call reapproval through its displayed witness. These integration additions have not individually observed native RED. Local frontend parse,12 Python tests, YAML/workflow equivalence and bash syntax pass; native SDK build still pending.

# Stage 6 completion implementation plan

> Execute inline with executing-plans and test-driven-development; one fresh whole-branch review after the remaining vertical slices. The owner authorized all Stage6 on2026-10-23 and explicitly approved the necessary UI additions described below. Do not ask to continue between authorized tasks.

**Goal:** Complete S6-04b, S6-05, S6-06 and S6-07 using the existing Runtime, Policy kernel, managed files and Settings.
**Architecture:** Preserve original ToolCall/Run identity and dispatched-before-executor. Persist the system-consent checkpoint with the existing call. Carry trusted frozen Run destination into file preparation. Consume only immutable FileAsset bytes through ManagedFileStore and its existing lock; use ConversationSessionStore removal reservations for warm/pending references. Sanitize results before durable storage or provider continuation. Keep Policy computation in the existing kernel.
**Spec:** Blueprint fffca086f4451a7bd0988959058ddcfe5eb6c13d:CONTEXT,developmentplan Stage6,ToolRuntime sections4–7/9/12/14/16,security permissions/data-egress; existing2026-10-07-stage6-policy-foundation.md section7.
**Base:** main e2e31972cd894da96ef110c8a2ebc3078cfd7d61/tree3cb0433cc2576a2f0539b86900aae32b6a4fbd09, mergedPR39. Exact source full39807102425 failed only Pad first-edge; Phone1162Swift/20XCTest/79UIpassed plus1Padskip. Owner accepted carrying knownissue40; preserve all RED provenance, do not claim repaired or fullGREEN. Post-merge39888595366 subsequently passed the normal Phone/Pad gate. Isolated reused worktree; branch codex/stage6-completion-20261023. OriginalUIcheckout/PR37 remain untouched.

## Approved UI scope

- Settings→Agent adds Callable Tools: actual availability, action policy, cap limitations, scope/subject/lifecycle disclosure and revocation, actual system state.
- Existing approval card adds conversation-scoped permission only when valid, with exact file version and frozen provider destination. Keep current card typography/layout structure and motion.
- System permission consent is separate from Tool grant: request/decline interaction; pressing request does not issue a grant.
- Existing page geometry, Sidebar/Composer gestures, menu animation, resources and signing are frozen. No unrelated Calendar/microphone/location tools or fabricated permission status.

## Existing boundaries verified

- ToolRuntime.complete/executePrepared and PersistenceStore+ToolAuthorization own the existing approval/dispatch transaction.
- ToolCallState already includes waitingForSystemPermissionConsent; current recovery/projection only fully wires ordinary approval. Add the missing owner path rather than inventing a second Run state machine.
- RequestConfigSeed already freezes providerInstanceID and full endpoint; Files destination comes from this seed, not mutable Settings or model arguments.
- ManagedFileStore.withVerifiedBlob holds the process file lock and verifies version/fingerprint. FileAsset versions and advanceFileAsset exist. Extend publication under that lock with expected-version checks.
- FilesWorkspaceModel already uses ConversationSessionStore.withFileRemovalReservation. Reuse this exact owner for tools; do not create a parallel draft reference list.
- AppAssembly currently uses ToolRegistry.empty; production exposure occurs only with real executors and finished settings/authorization/result guards.

## Task 1 — S6-04b system consent and scoped approval

Ownership:App/Tool runtime/system-access boundary; App/Persistence consent migration/checkpoint; existing AgentRuntime/ConversationRuntime/RunRecovery; ToolApprovalProjection/CardView. Dependencies:existingS6-04a.

- [x] Native behavioral RED: alwaysAllow cannot request OS permission or execute when notDetermined; explicit consent requests once without granting authority; deny/restrict/unavailable never dispatch; user decline returns typed result; recovered pending/requesting states reread actual status and never re-prompt automatically; stale witness/owner and policy tightening stop request/dispatch.
- [x] Reuse the existing call state; persist consent versus request-in-flight, bind request to original attempt/intent, guard duplicate clicks. Actual OS queries remain external to SQLite; recheck immediately before dispatch and handle actual executor permission failure.
- [x] Add conversation grant through the existing DB-scoped grant issuer with exact subject/action/revision/resource/destination. Approval widening is explicit for the original call; Settings widening still cannot wake old waits.
- [x] Project and route distinct Tool approval versus system consent in live and recovered loops; never silently hide a waiting call. Current built-ins and managed sandbox files require no OS prompt; unsupported capabilities are unavailable. Injectable native tests do not claim physical OS permission acceptance.
- [x] Observe native GREEN for Task1 before Files integration.

## Task 2 — S6-05 Files.read, egress and result guard

Ownership:App/Tool/Builtins Files executor; trusted preparation context in originalToolRuntime; ManagedFileStore bounded access; result sanitation; native tests. Dependencies:Task1.

- [x] Native RED for exact asset/version/fingerprint and Run provider endpoint; reject model paths/extra destination, corrupted/symlinked/outside bytes, replaced versions, incomplete authority, denied policy and cross-destination grant reuse.
- [x] Freeze trusted destination from the original Run seed. Declare local-data→provider egress in the action. Import/message attachment does not grant model-initiated access.
- [x] Read bounded supported UTF-8 text through verified immutable bytes; oversized/binary input yields a stable reference/error without unbounded loading. Budgets are engineering limits, not platform claims; test exact byte boundaries and multibyte text.
- [x] Validate result kind and UTF-8 byte budget; redact known credentials and credential-shaped fields before persistence/UI/provider. Stable safe error codes must not include raw error descriptions or secret-bearing arguments. No Tool content becomes a permission instruction.
- [x] Native GREEN includes real provider continuation with sanitized result and frozen endpoint, not compile-only tests.

## Task 3 — S6-06 managed create/modify/delete

Ownership:existing ManagedFileStore/FileAsset persistence, file tool actions, ConversationSessionStore shared reservations; outcome confirmation in original recovery. Dependencies:Task2.

- [x] Native RED for immutable old Message/Run versions, expected-version CAS, cancellation before/after metadata commit, shared digest references, symlink escape, pendingSend/warm draft/twoPane removal protection and concurrent modify/delete.
- [x] Create/modify publish protected immutable bytes, then metadata/operation receipt atomically under the same existing file lock. Bind new identities to the original frozen call; never reinterpret an approved target.
- [x] Delete uses the same session reservation and durable reference checks as FilesWorkspace; no warm/pending reference window. Retain historical message/run content versions.
- [x] Dangerous actions require explicit scoped confirmation and respect hard caps. An operation receipt may confirm completed work after crash; unresolved dispatched writes remain indeterminate and are never blindly executed again.
- [x] Native GREEN includes crash-window/duplicate-recovery controls and actual file-byte observations.

## Task 4 — S6-07 Settings and production exposure

Ownership:Settings tools model/view, AppAssembly/AppShell wiring, original runtime exposure and native UI tests. Dependencies:Tasks1–3.

- [x] Native RED for persisted action policy/revocation, unavailable executor, capability limitations, settings tightening blocking the original card, widening not releasing old waits and exact endpoint/content scope invalidation.
- [x] Use the approved Settings→Agent entry with existing Form/navigation styles. Show real executor/system availability; exact subject/scope and invalidation reason. Persistent policy and runtime grants remain distinct.
- [x] Inject the real built-in/file registry and shared session/file/credential owners into production. Freeze exposed tools into the existing Run snapshot and retain provider capability guards.
- [x] Native UI controls cover scope choice, explicit system consent with a test-only driver, Settings tightening/return to old card, safe denied continuation, readable destination/file version, and existing Composer/Sidebar regressions.
- [x] New product/source changes require normal exact-head full Phone/Pad gate; isolate genuine infra/knownissue40 outcomes without erasing them.

## Integration and evidence

- [x] One fresh-context whole-branch review; one corrective RED→GREEN pass for Critical/Important; record Minor rulings.
- [x] Restore final normal workflow and remove all diagnostic-only selectors before final source verification. No retries/skip/cancelled/in_progress become acceptance.
- [x] Local static parse/YAML/path/hygiene; native XcodeGen/build/unit and relevant integration/UI tests. Record actual counts, skips, host restarts, sourceSHA/tree and artifact provenance.
- Merge authorized ready slices/whole branch with expected-head guard; definitive merge tree equality and separate post-merge CI are recorded on [PR41](https://github.com/54zhien/Zen-Agent/pull/41).
- [x] Update README and Stage6 gate matrix with implementation/native/device status separately. Stage7–10, unrelated UI redesign and signing/IPA are excluded.

## Native closure receipt

Normal full CI39913184297 passed at c4b5e987821b73945143ae72fcea477c0682160a:
1,224 Swift tests/187 suites,20 XCTest unit tests,85 Phone UI passes plus one Pad-only
platform skip, and Pad1/1. All six Stage6 UI cases passed in the same full run. See the
Stage6 gate for raw-log/artifact receipts, preserved RED/cancelled runs, review dispositions
and physical-device boundaries. Final integration changes only these acceptance documents;
application, tests and build inputs are checked byte-identical to the tested source.

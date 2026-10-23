# Stage 8 Skills and Environment design proposal

Status: approved for execution on 2026-10-24. The owner approved the UI proposal and then explicitly approved both remaining recommended decisions, asking to complete the entire Stage 8 with the same constraints.

## Verified starting point

- Blueprint main `99d30b815651fe987bab9f88e269a84a89318625`: development plan Stage 8; CONTEXT; Agent capabilities/extension sections 1-3, 6-10; Prompt/Soul/Memory section 2; security sections 3, 6, 8, 13.1, 14; message/data snapshot and credential boundaries. Read through the authorized GitHub connector on 2026-10-24.
- Stage 7 receipt `f335204b387e9a5ca10fa2091dbb24e4e3368296`, draft/open/unmerged PR42. Its unchanged product/test/build inputs were tested at source `e6cf31a92f8d9dea741a629fef68957d1c05e500`, tree `5791a1a17720cfee76c8b9c1f2d387372046b3ce`.
- Original normal workflow_dispatch CI39973149365 is currently completed/SUCCESS, verified through the GitHub API. The Stage 7 record reports 1,266 Swift tests, 20 XCTest units, 89 Phone UI passes with one expected Pad-only skip, and the separate Pad case passing. This is a baseline receipt, not Stage 8 verification or physical-device acceptance.
- Remote main remains the Stage 6 base `49e77fb4eeaee7f4fad1b97b319d6b1de5cb991f`. Stage 8 will stack on the tested Stage 7 branch; no merge into main or takeover of the parked UI/Stage 6/Stage 7 worktrees is authorized by this proposal.
- A fresh app-managed worktree has been created from f335204. Existing production code has no Skill repository/router or Environment store. PromptComposer is pure, CredentialStore already owns protected SecretValue and generation-aware references, and ToolRuntime already owns policy evaluation and dispatch.

## Approved owner decisions

1. UI (APPROVED): reuse the existing native Settings Form. Add Agent -> Skills and Agent -> environment variables. Skill list/detail exposes enable state, source, instructions and dependency status; a built-in may be copied to an explicitly saved user-created version. Environment editing exposes Global/Skill scope, plain/secret kind, masked secret state, and dependency-aware confirmed deletion. Wire the existing Composer plugin entry to Skill selection and display its selection. Preserve the existing menu layout, text arrangement, animation and gestures. Extend the data/privacy explanation.
2. Manual activation lifetime (APPROVED): next successful Send commit only. The selection is editable/cancellable before Send; a failed Send commit retains it. Successful commit consumes the draft selection and durably binds it to the original Run, including its subsequent tool steps/recovery. Blueprint explicitly leaves Composer plugin selection lifetime to the owner.
3. Environment precedence (APPROVED): Global base followed by overrides from the particular active Skill. Only its declared references are selected; unrelated Skill scopes do not participate. Implement actual Global and Skill scopes in Stage 8. MCP/Subagent contexts wait for their own stages and must receive their own explicit inheritance rules. Blueprint explicitly leaves scope precedence to the owner.

All three decisions are approved. Continue through the full stage without repeating these approval questions.

## Intent and approach

Complete the entire Stage 8 sequence: Global environment storage and immutable config identity; Skill definitions/repository; built-in enable/disable; deterministic manual activation; dependency checking; bounded rule-based routing; then actual Skill-scoped environment resolution. Prove that enabled does not mean injected and a Skill never grants Tool authority.

Reuse GRDB within App/Persistence, CredentialStore/Keychain for secrets, the existing Send transaction and Run snapshot, pure PromptComposer, and the existing ToolRegistry/ToolRuntime/Policy. A separate extension runtime/database would duplicate cancellation, recovery and deletion owners. An external or model-based router would add an unrequested data destination/cost without evidence of need; initial routing is local and deterministic. These are builder implementation choices within the approved scope.

MCP transports, Subagent runtimes, remote marketplaces, embeddings and additional model requests are outside Stage 8. No feature should be represented as available solely because a setting was persisted. User-created copies use the same real activation path; an import flow is not implied by this proposal.

## Ownership and durable identity

- Environment domain/service owns key validation, explicit context resolution, dependency discovery, safe errors and credential lifecycle coordination. Persistence alone owns transactional metadata, unique scope/key constraints, immutable revisions and content-free revocation metadata.
- Skill domain/service owns the bundled catalog, immutable instruction/dependency revisions, enable state, user-created copies, dependency evaluation and the pure router. Built-in definitions cannot be edited in place. No Skill receives CredentialStoring or a permission-writing interface.
- ConversationRuntime owns preparation of selected Skill/context references. AgentRuntime/RunRecovery/RunRequestRebuilder own validation and continuation using the original Run identity. The UI only submits commands and displays projections.
- Settings owns explicit saves and input lifetime; Composer retains manual selection with the original Conversation/draft owner. Switching panes, cancelling a menu or a failed commit must not transfer/consume another draft's selection.

## Prompt and activation boundary

Manual selection must deterministically activate only the intended, enabled, dependency-valid Skill revision. Local automatic routing considers enabled definitions and the current committed user request, selects a bounded relevant subset, and selects none for unrelated input. Never dump every enabled instruction block into a request.

Freeze Skill identity/revision and the non-secret environment config identity for the actual Run. Ordinary edits affect later Runs; continuation/recovery does not reread current Skill bodies or mutable environment dictionaries. Older snapshots decode without invented activations. Malformed references fail closed.

Activated workflow instructions remain below the current user's explicit request and all Runtime/Safety/ToolPolicy rules. User-created/external instruction text stays untrusted workflow context. It cannot change the system-role safety material, directly read credentials, expand exposed tools, grant approval or change the target/destination of a frozen tool intent. Required dependency presence is distinct from permission to execute it; actual calls always traverse the same existing policy/approval pipeline.

## Environment and secrets

Validate bounded keys and values, same-scope uniqueness and real Skill targets. Scope/key are a variable identity and remain fixed after creation; changing either requires an explicit dependency-aware delete and a new variable. Value edits alone create immutable revisions, so frozen references never silently change key or scope. Resolve only declared references in an explicit context. Missing keys, cycles/invalid references and unsupported scope targets produce typed non-secret errors; never merge all stored scopes into a global dictionary or use process setenv.

Plain values may be fixed by immutable revision for the Run. Secret values are never Codable configuration or snapshot payloads: store only credential reference plus binding/config identity. Persist a reference only after Keychain provisioning succeeds. Failed metadata persistence must clean up only the newly owned credential, without deleting shared or previously committed references. Reuse existing Keychain accessibility/synchronization policy.

Secret interpolation into Prompt, Skill text, Memory, diagnostics or ordinary Tool Result is refused. Resolve secrets only at a declared genuine executor boundary, with exactly scoped references and binding validation; a Skill's dependency declaration alone cannot authorize secret access. Existing tools that have no credential input must not acquire one merely to demonstrate plumbing. Native fake-executor tests can prove the resolver boundary without presenting a new user-facing capability.

Builder decision after the focused credential/executor audit: ordinary environment-secret replacement provisions a fresh opaque reference for the new immutable revision. Existing CredentialStore.refresh overwrites bytes under the same generation, and rebind deletes the old generation, so neither preserves an ordinary historical environment revision. Retain the old reference only while its non-erased revision can still be used, including by a nonterminal frozen Run. Explicit deletion/revocation invalidates those dependencies; cleanup may log out only an owned reference with no surviving consumers. Use the existing globally unique opaque reference namespace and existing Keychain policy, without adding a fake API-key identity or changing account encoding.

Builder-check resolution: Stage 8 delivers real Keychain-backed storage, reference/binding validation and scoped resolver behavior, but does not claim secret-backed production actions. The current Calculator/Current Date/Device Info/Files executors have no credential input. Do not invent one, add a Skill script executor, or expose a get-secret tool merely to demonstrate resolution. A future genuine credential consumer belongs to its owning feature, such as Stage 9 MCP. Until then, the UI must state that saved secrets are execution configuration and are not sent to the model; tests through a trusted fake executor prove isolation without representing a shipped action. A configured secret is not proof that a Skill has a usable authenticated tool.

Known-secret exclusion/redaction also needs an Environment integration audit: existing Memory validation and ToolRuntime output checks currently enumerate provider credentials only. Adding Environment must not let a previously saved secret be accepted as plain/Skill/Memory content or leak through executor output. Keep raw-secret access within the trusted validation/redaction boundary; never hand a Skill broad CredentialStoring or all stored environment values.

Existing tool exposure is frozen from the registry. The code map found that AgentRuntime.processToolBatch currently delegates a returned call to ToolRuntime without checking membership in that Run's exposedTools. If activation changes exposure, enforce exact exposed membership/revision at that runtime boundary and cover forged/unexposed calls; do not mistake this check for Tool Policy or grant creation. Stage 8 instructions alone never add registry executors or widen a model's tool capability.

## Deletion, tightening, failure and cancellation

Before deleting a variable or user-created Skill, show affected definitions/configurations and nonterminal Runs. Confirmation must stop/settle dependent execution or retain a pending destructive operation until a safe point; it must never leave an executing Run half-configured. Explicit deletion/security tightening overrides immutable history: no subsequent provider handoff, tool dispatch or recovery may use erased/revoked content. Ordinary edits remain separate from destructive revocation.

Reuse and extend the existing per-database handoff/deletion coordination rather than introducing independent locks that can deadlock. Stop-state and attempt checks remain under the actual handoff/dispatch gate. A late request/result cannot reopen a stopped Run or write into another owner. Cold recovery must settle the original Run and release its active slot. Existing uncertain external-file-operation proof must be confirmed through its original path without replaying a side effect.

Destructive flow first marks the dependency revoked/deleting under the existing gate, then asks the original ConversationRuntime owner to Stop/settle affected Runs outside that gate, and only removes bodies after they are terminal. Failed settlement leaves a visible retryable pending deletion; it does not reactivate the dependency or switch identity. Keychain cleanup uses a durable content-free retirement queue so a temporary Keychain failure can be retried without retaining deleted plain/Skill bodies.

Remove erased user-created instruction/plain-value revisions from content storage; retained diagnostics contain only minimal identifiers/fingerprints/time. Delete Keychain bytes only when the operation owns them and no surviving reference requires them. Data/privacy language acknowledges that local deletion cannot retract content already transmitted to a provider or historical system backups.

## Planned vertical slices and acceptance

1. Global environment: real disk migration/reopen, scope/key validation, immutable config identity, Keychain-first persistence/failure cleanup, generation checks, no secret in SQLite/encoding/errors/logs, dependency-aware deletion. Add approved Global management UI only after approval.
2. Skill repository and manual activation: bundled definitions, enable state, immutable copies/explicit saves, dependencies, exact Send commit selection, actual provider request/frozen restoration, policy-denied and ask-before-execute cases. Add approved Skills/settings/Composer interaction.
3. Router and scoped environment: deterministic relevant subset, unrelated/no-match controls, explicit selection behavior, Global/Skill precedence, scope isolation, missing/revoked bindings and only declared references. No MCP/Subagent implementation.
4. Whole-stage erasure/recovery, review and delivery: queued Stop/delete, displayed approval revocation, disk-reopened cold ownership and side-effect proof; native dark/largest-type/portrait/landscape UI inspection, draft preservation, and complete normal Phone/Pad gate.

Use actual RED -> GREEN for consequential behavior. Compile errors, static checks, focused diagnostics and skipped/cancelled jobs remain separately identified. Windows checks do not replace xcodegen generate, native build/tests in macOS CI. Keep normal workflow/project/Config inputs intact; focused diagnostic runs cannot close the stage. Preserve failed-run provenance and never rerun unchanged work simply to obtain green.

Follow the previous inline execution method with delegated read-only exploration and one independent whole-branch review, followed by its corrective pass and required validation. Record builder rulings and any genuinely deferred minor findings. Finish with a draft Stage 8 PR stacked on Stage 7 and an appropriate Blueprint decision update after the owner's answers; attach every created PR. No merge, IPA delivery, physical-device claim or Stage 9 work is part of this scope.

# Stage 8 Skills and Environment implementation plan

> **For agentic workers:** Use superpowers:executing-plans inline with superpowers:test-driven-development. The owner approved the full stage, UI additions, next-request manual activation and Global -> active-Skill precedence. Execute all tasks without repeated permission checks. Delegate read-only investigations and one whole-branch review.

**Goal:** Complete versioned Environment configuration and usable built-in/user-created Skills, deterministic manual activation and bounded routing without widening Tool authority or exposing secrets.
**Architecture:** PersistenceStore owns immutable revisions and atomic Send associations; EnvironmentRuntime/SkillRuntime own validation and selection. ConversationRuntime freezes actual references; AgentRuntime/RunRecovery reuse and validate them under the existing per-database handoff gate. Settings/Composer consume the same services and preserve draft ownership.
**Tech Stack:** Swift 6, iOS 26, SwiftUI/UIKit, GRDB, existing CredentialStore/Keychain, XcodeGen/macOS CI.
**Spec:** [Approved design](../specs/2026-10-24-stage8-skills-environment-design.md).
**Base:** Stage 7 f335204b387e9a5ca10fa2091dbb24e4e3368296; branch codex/stage8-skills-environment-20261024. Main and other worktrees are untouched.

## Global constraints

- Global base then only the active Skill's overrides; only declared keys participate.
- Composer selection belongs to its Conversation draft and is consumed only after successful Send commit; subsequent steps/recovery use the original durable selection.
- SecretValue never becomes a Codable config, Prompt, Memory, diagnostic or ordinary Tool Result. Fresh opaque references preserve ordinary secret revisions; explicit erasure/revocation wins.
- Skill instructions do not grant permission or add tools. Required tool existence is separate from Tool Policy and approval.
- UI changes are limited to the approved Settings/Composer capability additions. Preserve existing geometry, text arrangement, animation, gestures and input owner.
- No MCP/Subagent runtime, marketplace, model router, extra model call, merge or IPA delivery.
- Full normal source CI stays unchanged. Preserve native RED, compile failures and failed full gates separately; physical acceptance remains separate.

## Review focus

- Two editors save concurrently or secret provisioning succeeds but metadata/CAS fails: preserve the committed version and clean up only newly owned bytes.
- A delete/disable races a queued provider request or displayed Tool approval: future dispatch fails closed and the original Run settles without replay.
- A committed Send fails preparation or its response is lost: original selection is durable and duplicate submission cannot change its payload.
- Environment overrides, unknown/cyclic references and instruction text containing secret-like values: no sibling-scope or secret escape into context/Memory/results.
- Cold recovery of deleted Skill/env dependencies with existing file-operation proof: release original active slot and confirm proof without repeating writes.

## Task 1: Global Environment store and credential boundary

**Files:** Create App/Environment/EnvironmentTypes.swift, EnvironmentRuntime.swift; App/Persistence/Migrations+Extensions.swift, EnvironmentRecord.swift, PersistenceStore+Environment.swift. Modify Migrations.swift and trusted known-secret validation helpers. Tests EnvironmentPersistenceTests.swift, EnvironmentRuntimeTests.swift.
**Interfaces:** EnvironmentScope.global / .skill(id), EnvironmentRevisionReference(variableID,revisionID), EnvironmentItem(id,revisionID,key,scope,value), EnvironmentStoredValue.plain(String)/.secret(CredentialBindingSnapshot). Store list/save CAS/resolve exact versions/delete and enumerate owned references. Runtime savePlain/saveSecret validates content; secret provisioning precedes reference commit, failed commit retires only fresh reference; freeze/resolve rejects erased dependencies.

- [ ] Native RED: real v21 disk upgrade preserves data but lacks Environment schema; immutable versions and XOR plain/reference constraints.
- [ ] Implement v22 schema and Global domain/store with same-scope uniqueness, bounded inputs and immutable revisions.
- [ ] RED then GREEN for CAS, key validation, plain-value safety, secret write-before-attach, failed-write cleanup, frozen old secret identity, binding revocation and disk reopen.
- [ ] Audit Memory/Skill/plain/result secret exclusion at trusted boundary; never expose broad CredentialStore to Skill content.
- [ ] Run all native units, record source/diagnostic distinction and commit evidence. Expected: App build + all existing units and Environment tests pass.

## Task 2: Skill catalog, manual activation and approved management UI

**Files:** Create App/Skills/SkillTypes.swift, SkillCatalog.swift, SkillRuntime.swift; App/Persistence/SkillRecord.swift, PersistenceStore+Skills.swift; App/Settings/SkillSettingsModel.swift, SkillSettingsView.swift, EnvironmentSettingsModel.swift, EnvironmentSettingsView.swift. Modify Migrations+Extensions.swift (new migration), SettingsWorkspaceModel/View and privacy view, SendCommand, SendCommit/persistence, Composer draft/Pane/Host interfaces, ConversationRuntime, PromptComposer, RunExecutionSnapshot and RunRequestRebuilder.
**Interfaces:** SkillDefinition has stable ID/source, immutable revision, instructions and declared required/optional tools, MCP IDs, env keys and router terms. SkillRuntime.seedCatalog/list/copy/save/setEnabled/prepare/resolveFrozen uses registry and EnvironmentRuntime. SkillActivationReference(skillID,revisionID,environment bindings) carries no text or secret; frozen references associate with original Run. SendCommand.selectedSkillIDs defaults empty for compatibility and is part of submission digest. Durable Send association is atomic; UI clears only its original draft generation after commit.

- [ ] RED: actual built-in enable/copy/immutable edit, manual-selected-only provider request, legacy snapshot compatibility and stale/missing dependency refusal.
- [ ] Implement two modest built-in workflows using existing Calculator and Files tool IDs. No new executor or authority.
- [ ] RED: duplicate submission with changed Skill selection, failed Send retains draft selection and exact original Conversation ownership.
- [ ] Implement next-request manual selection through existing plugin entry and durable Send boundary. Selected instructions remain untrusted user/workflow context with explicit current-request priority.
- [ ] Implement approved native Forms, explicit saves, dependency summaries and confirmed deletion. Secrets stay masked with no reveal path. Use existing focus/close owner and safe typed errors.
- [ ] Native units + focused management/activation UI GREEN; inspect native captures including dark/largest-type inputs. Expected: no draft/selection transfer or unrelated UI modification.

## Task 3: Dependency-aware router and scoped Environment

**Files:** Create App/Skills/SkillRouter.swift; extend EnvironmentRuntime/SkillRuntime, store dependency queries and approved scope editors. Tests SkillRoutingTests.swift, SkillEnvironmentTests.swift, SkillPromptIntegrationTests.swift.
**Interfaces:** SkillRouter.select(query:definitions:) returns a deterministic bounded subset. Explicit selection is authoritative and failure is visible; automatic routing skips unavailable definitions. Per-Skill environment freezes only declared key references, with Skill overriding Global. Plain interpolation uses pinned revisions; secret interpolation is refused. Resolver accepts trusted frozen binding and declared key, never arbitrary model-provided credential reference.

- [ ] RED: enabled is not injected wholesale, unrelated input selects none, local bilingual positive routes, deterministic limit/order and manual precedence.
- [ ] Implement simple local routing and real dependency status, distinguishing present/ask/denied/missing and unsupported MCP prerequisites.
- [ ] RED: Global/Skill override, sibling isolation, missing variables, malformed/cyclic references, secret Prompt refusal and immutable recovery after edits.
- [ ] Implement scoped references and revision/fingerprint validation; actual Secret bytes resolve only at trusted executor seam tests, with no shipped fake secret consumer.
- [ ] Native all-unit + focused new UI GREEN. Expected: required dependencies cannot grant Tool permissions or expand exposure.

## Task 4: Erasure, recovery, review and complete source gate

**Files:** Extend existing AgentRuntime/ToolRuntime/RunRecovery/RunRequestRebuilder and dependency erasure services, snapshot codecs; add SkillErasureTests.swift and native SkillsSettingsUITests.swift/EnvironmentSettingsUITests.swift. Add tasks/stage8-skills-environment.md and README receipt; update Blueprint decisions on a draft branch/PR.

- [ ] Native RED: queued Stop/delete, displayed approval revocation, user-created Skill erasure, environment binding revocation, cold-original-owner settlement and existing file-write proof preservation.
- [ ] Implement minimal checks under the existing per-database handoff gate. Dependency destruction settles/stops original execution before removal; no hidden body copy, stale dispatch or replay.
- [ ] Run one independent whole-branch review against base f335204; reproduce and fix material findings in one corrective pass with native RED -> GREEN and green suite. Record all rulings/deferred minors.
- [ ] Inspect actual dark/light/largest-type portrait/landscape screenshots and interaction. Preserve existing resize-dismiss policy and exact Form-visible navigation harness.
- [ ] Push final source and run unchanged normal ci.yml Phone/Pad gate. Expected: hygiene, XcodeGen/build, all unit tests, complete Phone UI and actual Pad axis pass without host restart or softened assertions.
- [ ] Create/attach draft implementation PR stacked on Stage 7 and draft Blueprint decision PR, preserve failure receipts, record exact source/tree/jobs and tested input equivalence. Keep both unmerged; physical acceptance open.

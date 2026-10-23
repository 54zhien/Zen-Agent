# Stage 7 Memory implementation plan

> **For agentic workers:** Use superpowers:executing-plans inline and superpowers:test-driven-development task by task. The owner authorized the whole stage and approved the UI and product decisions in the spec. Continue between tasks without asking again. One independent whole-branch review at the end.

**Goal:** Complete transparent Memory storage/management, retrieval/frozen Prompt context and safe automatic formation.
**Architecture:** Existing PersistenceStore owns transactional records/revisions/provenance; MemoryRuntime owns validation and orchestration. Existing ConversationRuntime/AgentRuntime/RunRecovery consume frozen version references and guard every provider handoff against erasure. Settings uses its existing host and focus owner.
**Tech Stack:** Swift 6 strict concurrency, iOS 26 SwiftUI, GRDB confined to Persistence, XcodeGen and macOS CI.
**Spec:** [Stage 7 design](../specs/2026-10-23-stage7-memory-design.md).
**Base:** PR41 merge `49e77fb4eeaee7f4fad1b97b319d6b1de5cb991f`; managed isolated worktree, branch `codex/stage7-memory-20261023`. Original UI and Stage 6 worktrees are read-only to this task.

## Global constraints

- UI limited to the owner's approved Settings Memory and privacy additions.
- Preserve current system-role prompt, tool authority, active Run identity and uncertain-effect receipts.
- Secret never enters Memory, ordinary logs or snapshots; safe failures never emit candidate text.
- Source Conversation final deletion retains Memory with source-missing metadata. Undo does not alter provenance.
- Memory shares protected system-backed-up User Data DB; no cloud sync, vectors or extraction network call.
- Immutable revision references only in Run snapshots; edit affects new Runs, erasure blocks future use by any Run.
- Keep final normal CI/workflow/project inputs; focused diagnostic evidence is not the full gate.

## Review Focus

- User deletes Memory while a provider handoff or tool continuation is queued: no later handoff uses erased text.
- A credential backend becomes unavailable: fail closed for Memory without failing a successful user Run or exposing raw errors.
- Clear All or disabling auto races candidate commit: no stale candidate resurrects data or bypasses the toggle.
- Multiple Scenes save the same revision or replay extraction: no lost user edit, duplicates or stale overwrite.
- Chinese/English negation, temporary context, quoted instructions and assistant/tool assertions: no speculative user fact is promoted.

## Task 1: Memory Store, service and approved management UI

**Files:** Create `App/Memory/MemoryTypes.swift`, `MemoryRuntime.swift`, `MemoryContentPolicy.swift`; `App/Persistence/MemoryRecord.swift`, `Migrations+Memory.swift`, `PersistenceStore+Memory.swift`; `App/Settings/MemorySettingsModel.swift`, `MemorySettingsView.swift`. Modify `Migrations.swift`, existing Settings workspace model/view, privacy view and database initialization. Tests `MemoryPersistenceTests.swift`, `MemoryManagementTests.swift`, `MemorySettingsUITests.swift`.
**Interfaces:** `MemoryRecord`/`MemoryRevisionRecord`/`MemorySourceRecord` are Sendable records. Store exposes `memorySettings()`, `memories()`, `memoryRevision(id:)`, CAS saves and erase. `MemoryRuntime` accepts store/credentials, exposes validated `save`, `delete`, `clear`, `setEnabled`, and async `setAutomatic`; UI owns no database truth.

- [ ] Add compiling contract fixtures/stubs and native behavioral RED for real disk migration/reopen; immutable versions/CAS; explicit-save versus keystroke; complete erasure; known/escaped credentials and unavailable credential backend; no automatic extraction before real capability.
- [ ] Implement v20 migration, domain/store ownership and content validation; ensure source missing is set by existing finalized-deletion transaction without cascade deleting Memory.
- [ ] Add native user-data protection/backup policy to existing database initialization, preserving shared backup intent.
- [ ] Implement approved Form/entry/detail/editor with existing focus/close ownership and typed safe failure. Hide automatic switch until extractor available.
- [ ] Observe native GREEN for storage/service and UI management. Commit source and evidence separately; no full-stage completion claim.

## Task 2: Retrieval, immutable Prompt context and erasure

**Files:** Create `App/Memory/MemoryRetriever.swift`, `MemoryAccessGate.swift`; modify existing PromptCompositionInput/PromptComposer, PromptExecutionSnapshot decoding/encoding, ConversationRuntime preparation, AgentRuntime provider handoff, RunRequestRebuilder and RunRecovery. Add store frozen-reference helpers. Tests `MemoryRetrievalTests.swift`, `MemoryPromptIntegrationTests.swift`, `MemoryErasureTests.swift`.
**Interfaces:** `MemoryRevisionReference(memoryID:revisionID:)`; `MemoryContext(reference:content:)`; `MemoryRetriever.select(query:records:)` returns bounded active subset; `MemoryRuntime.retrieve(query:)` validates safe text. `resolveMemoryReferences` resolves exact immutable rows or throws `MemoryError.erasedDependency`. `MemoryAccessGate.shared.withRead/withWrite` linearizes asynchronous provider handoff and destructive Memory operations.

- [ ] Native RED for bilingual relevance/unrelated query, 6/1,024/4,096-byte limits, toggle, old-snapshot decode, actual fake-provider request role, new-Run retrieval and old-Run edit stability.
- [ ] Implement deterministic retrieval, exact version freeze and low-priority user context; use no mutable Settings inside PromptComposer/rebuilder.
- [ ] Native RED for deletion while an async handoff is in flight/queued, warm continuation and disk-reopened suspended recovery; missing versions produce explicit invalidate and no request/tool replay. Preserve existing file-operation proof.
- [ ] Implement shared async dispatch/erase gate, transactional version removal and original Run-owner invalidation. No snapshot/body hidden copies.
- [ ] Observe native GREEN with all unit target tests and task integration cases. Commit.

## Task 3: Conservative automatic extraction, dedup and conflict

**Files:** Create `App/Memory/MemoryCandidateExtractor.swift`; extend MemoryRuntime and persistence commit/receipt helpers; wire successful Parent completion in ConversationRuntime; enable approved auto switch. Tests `MemoryExtractionTests.swift`, `MemoryFormationIntegrationTests.swift`, real sample fixtures in those tests.
**Interfaces:** `MemoryCandidate(content:factKey:source:)`; extractor consumes only committed current user text; `MemoryRuntime.formAfterCompletedRun(runID:)` is idempotent, bounded, best-effort and policy-controlled. Store commit atomically checks settings/cutoff/source identity and receipt before insert/dedup/conflict update.

- [ ] Native RED for Chinese/English stable samples, explicit remember, temporary/uncertain/negative/quoted/assistant/tool/secret exclusions; deterministic caps and non-fatal errors.
- [ ] Native RED for exact/normalized duplicates merging provenance, stable key replacement, manual edit priority, repeated completion, cold startup without backfill, clear/disable racing delayed extraction and explicit new fact after deletion.
- [ ] Implement narrow local rules and typed safe refusal. No candidate body in receipts/logs; no additional provider/egress/model slot. Preserve old revision for frozen Runs.
- [ ] Wire production completion only after Tasks1–2 evidence passes; enable auto default and UI only with real extractor. Verify real completed Run creates a visible/editable record and a subsequent relevant Run sends it.
- [ ] Observe native GREEN and record recognized-language/quality limits. Commit.

## Task 4: Whole-stage review, full gate and documentation

**Files:** Stage7 source/test range; `tasks/stage7-memory.md`, README and this plan. Blueprint owner-decision note and stage-plan unresolved list, in a separate Blueprint branch/PR.

- [ ] Reconcile spec coverage and changed-path scope. One fresh reviewer reads entire branch and Review Focus; fix Important/Critical with actual RED→GREEN once; record deferred minors/rulings.
- [ ] Run local YAML/path/hygiene and actual native XcodeGen/build/all unit/integration/approved UI. Final normal exact-head Phone/iPad gate remains mandatory; no diagnostic selector accepted as closure.
- [ ] Inspect new page screenshots at narrow width/largest text/light/dark and relevant keyboard/navigation behavior; report device and model-quality limits separately.
- [ ] Update README, gate matrix and exact SHA/tree/CI receipts. Create draft PR and attach it; leave merge for concrete final approval unless subsequently authorized. Preserve all failed/compile/cancelled provenance.

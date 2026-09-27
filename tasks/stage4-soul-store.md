# Stage 4 Soul Store and versions implementation plan

> Read the Blueprint's `Design/Zen Agent 开发规划.md`, `Design/CONTEXT.md`, and `Design/Zen Agent Prompt、Soul 与 Memory.md` before executing. This covers Stage 4 steps 3–4 only.

**Goal:** Persist one global Soul and append immutable instruction versions without changing existing Conversation or Run behavior.

**Architecture:** A new migration adds a singleton Soul pointer and separately stored SoulVersion rows. PersistenceStore creates the first version and advances the pointer transactionally, rejecting stale edits. No View, Runtime, or PromptComposer reads Soul yet.

**Tech stack:** Swift 6, GRDB, Swift Testing, XcodeGen, macOS CI.

**Spec:** Blueprint `Design/Zen Agent Prompt、Soul 与 Memory.md` §§3, 8, and `Design/Zen Agent 开发规划.md` Stage 4 steps 3–4.

## Constraints and review focus

- Existing Conversation data must survive migration; version text is user data, never a Tool permission.
- Advancing Soul creates a fresh version without changing prior versions; a stale edit cannot replace the current pointer.
- The version insert and current-pointer move are one transaction.
- The store is initially empty; no default personality or temporary Settings page is created.
- Conversation binding and prompt injection belong to later Stage 4 slices; no IPA in this slice.

## Task 1: Persistence behavior

**Files:** `Tests/ZenAgentTests/SoulPersistenceTests.swift`, `App/Persistence/Migrations.swift`, `App/Persistence/Records.swift`, `App/Persistence/PersistenceStore+Soul.swift`, `App/Persistence/PersistenceStore.swift`.

- [ ] Write failing tests for create, advance, prior-version stability, stale edit refusal, rollback, and disk reopen.
- [ ] Verify RED in macOS CI.
- [ ] Add v10 migration and minimal record/store API; reject updates to a SoulVersion row.
- [ ] Verify the final SHA with XcodeGen build and relevant tests in macOS CI.

## Task 2: Review and handoff

- [ ] Review scope, migration compatibility, diff whitespace, and secret patterns.
- [ ] Open a draft PR based on the prior Stage 4 Prompt PR; keep it unmerged.

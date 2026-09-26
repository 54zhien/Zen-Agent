# Stage 4 Conversation Soul binding implementation plan

> Read the Blueprint index, `Design/CONTEXT.md`, and `Design/Zen Agent Prompt、Soul 与 Memory.md` before implementation. This plan covers Stage 4 step 5, following the Soul Store and version slice in PR #7.

**Goal:** Bind each new Conversation to the SoulVersion current when its first Send commits; later global Soul edits must not change that binding.

**Architecture:** A v11 migration adds a global Soul enabled state and a separate Conversation-to-SoulVersion binding table. The existing Send transaction creates a binding only when it inserts a new Conversation and Soul is enabled. Reads expose the bound immutable version; no UI or Prompt injection is added here.

**Tech stack:** Swift 6, GRDB, Swift Testing, XcodeGen, macOS CI.

**Spec:** Blueprint `Design/Zen Agent Prompt、Soul 与 Memory.md` §3 and `Design/Zen Agent 开发规划.md` Stage 4 step 5.

## Constraints and review focus

- An old Conversation remains bound to its original version after the global Soul advances.
- Turning Soul off preserves versions and existing bindings; a new Conversation created while off has no binding. Re-enabling does not retroactively bind it.
- First-send Conversation, Message, Run, and optional Soul binding commit atomically; a failed Send leaves none of them.
- A replayed Send must not rebind, and deletion undo preserves the binding. Finalized deletion removes the Conversation binding while leaving global Soul versions.
- Existing Conversations from v10 upgrade have no inferred binding; no one-time Settings page, Prompt injection, or IPA in this slice.

## Task 1: Prove behavior before implementation

**Files:** `Tests/ZenAgentTests/SoulBindingTests.swift`.

- [ ] Add tests for first-send binding, old-version stability, disabled creation, re-enable behavior, failed Send rollback, deletion lifecycle, and v10 upgrade.
- [ ] Push tests and verify expected RED on macOS CI.

## Task 2: Persist binding at the existing owner

**Files:** `App/Persistence/Migrations.swift`, `App/Persistence/Records.swift`, `App/Persistence/PersistenceStore+Soul.swift`, `App/Persistence/PersistenceStore.swift`, `App/Persistence/PersistenceStore+Deletion.swift`.

- [ ] Add v11 migration and enabled/binding read-write methods.
- [ ] Insert the binding inside the existing Send transaction, only for a new Conversation.
- [ ] Remove the binding at finalized deletion; leave it intact during pending deletion and undo.
- [ ] Verify XcodeGen build, tests, and final SHA on macOS CI.

## Task 3: Review and handoff

- [ ] Review the migration, Send idempotency, deletion and error boundary, diff scope, and secret patterns.
- [ ] Open a draft PR based on PR #7, without merging or generating an IPA.

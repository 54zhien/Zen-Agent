# Stage 4 Soul prompt injection implementation plan

**Goal:** Use the Conversation-bound SoulVersion in the real Provider request and freeze the effective Soul revision in each Run's execution snapshot.

**Architecture:** ConversationRuntime reads the enabled state and bound version together during preparing. PromptComposer only receives prepared text and places it below Runtime/Safety, Provider Adapter, and Zen Core. The snapshot records the immutable version identity actually used, or nil when Soul is disabled or unbound. The existing Send transaction and provider execution flow remain the owners of their current boundaries.

**Tech stack:** Swift, GRDB, Swift Testing, XcodeGen, macOS GitHub Actions CI.

**Spec:** Blueprint `Design/Zen Agent 开发规划.md` Stage 4 and `Design/Zen Agent Prompt、Soul 与 Memory.md` sections 2–3 at `596a84d`.

## Constraints and review focus

- No Soul text may grant tools, credentials, provider capabilities, or Runtime state changes.
- A global Soul edit cannot change an old Conversation's bound version.
- Disabling Soul suspends injection without deleting a binding; a Conversation first sent while disabled remains unbound after re-enable.
- A completed Run snapshot must identify the exact Soul version used by its first Provider request; later settings changes cannot rewrite it.
- Legacy v1 snapshots must decode with no Soul, and no Secret may enter prompt or snapshot.
- Keep the current input Composer unchanged; do not build an IPA for this increment.

## Task 1: Real request and snapshot behavior

**Files:** `Tests/ZenAgentTests/SoulPromptIntegrationTests.swift`; `App/Persistence/PersistenceStore+Soul.swift`; `App/Runtime/RunExecutionSnapshot.swift`; `App/Runtime/ConversationRuntime.swift`; `App/Prompt/PromptComposer.swift`.

- [ ] Add behavior tests through `ConversationRuntime.send` with a recording Provider. Assert the actual first request and decoded Run snapshot for bound v1, after global edit to v2 in the old and a new Conversation, global disable/re-enable, and a Conversation first sent while disabled.
- [ ] Add a test proving Soul stays in a lower-priority system section, while user input and Quote remain user content. Check a tool-related Soul string never changes exposed tool schemas or Run capabilities.
- [ ] Add snapshot compatibility coverage for old serialized snapshots with no Soul field, and prove the encoded new snapshot records the exact effective version or nil.
- [ ] Commit and push test-only RED on the new branch; run CI and confirm failure reflects missing Soul prompt wiring.
- [ ] Add the smallest production change: atomically read effective bound version, freeze its immutable identity in the snapshot, then pass the same version's text to PromptComposer. A post-commit preparation read failure fails the durable Run as existing code does.
- [ ] Commit and push GREEN; run macOS CI and repair only evidenced failures.

## Task 2: Review and delivery

- [ ] Review affected send, snapshot, and tool continuation paths, including global enable races and legacy decoding.
- [ ] Verify diff scope, clean worktree, exact HEAD and passing CI; create a draft PR stacked on `codex/stage4-soul-binding`.
- [ ] Report which Stage 4 gate behaviors are proven and which still need a formal Settings host or device verification.

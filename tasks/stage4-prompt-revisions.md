# Stage 4 prompt revision wiring implementation plan

> For implementation in this branch, read `Design/Zen Agent 开发规划.md` and `Design/Zen Agent Prompt、Soul 与 Memory.md` in Zen-Agent-Blueprint first. Complete each task with a test and macOS CI result. This plan covers the first Stage 4 slice, not Soul or Memory.

**Goal:** Make the Core and Runtime/Safety revision IDs frozen in each Run select the actual instructions sent to the Provider.

**Architecture:** `PromptTemplateCatalog` owns immutable built-in text by revision. `PromptComposer` remains a pure assembler of prepared text. `ConversationRuntime` freezes current revision IDs, resolves the committed snapshot, and hands the resolved sections to the assembler. Unknown revisions fail rather than silently substituting current text.

**Tech stack:** Swift 6, XcodeGen, Swift Testing, the existing ConversationRuntime provider harness.

**Spec:** Zen-Agent-Blueprint `Design/Zen Agent Prompt、Soul 与 Memory.md` §§2, 7 and `Design/Zen Agent 开发规划.md` Stage 4 items 1–2.

## Global constraints

- Keep the W1 Composer geometry and behavior unchanged; produce no IPA in this slice.
- Preserve existing v1 snapshot encoding and the Send commit boundary.
- Keep credentials and mutable Settings out of PromptComposer.
- Preserve history, quote snapshot, and tool protocol behavior.
- Do not add Soul, Memory, Skills, or an early Settings UI.

## Review focus

- Unknown revision in a persisted Run must not silently use the newest instructions.
- A current Run's request must match its stored revision IDs.
- Provider adapter instructions must remain the frozen content from the snapshot.
- The current user and quote snapshots must occur once after history.
- A preparation failure after Send commit must leave a durable failed Run.

### Task 1: Resolve built-in prompt revisions

**Files:** Create `App/Prompt/PromptTemplateCatalog.swift`; modify `App/Prompt/PromptComposer.swift`; test `Tests/ZenAgentTests/PromptComposerTests.swift`.

- [ ] Add a failing test for v1 resolution and explicit rejection of unknown Core/Safety revisions.
- [ ] Add a failing test that `PromptComposer` uses supplied sections rather than hidden static constants.
- [ ] Implement the immutable v1 catalog and prepared-section input without I/O.
- [ ] Run the relevant tests in macOS CI and confirm they pass.

### Task 2: Wire the real Run snapshot to the request

**Files:** Modify `App/Runtime/ConversationRuntime.swift` and `App/Runtime/RunExecutionSnapshot.swift`; test `Tests/ZenAgentTests/PromptHistoryIntegrationTests.swift`.

- [ ] Add an integration assertion that decodes the committed Run snapshot and checks the actual captured Provider request against its resolved Core/Safety/Adapter content.
- [ ] Freeze revision IDs from the catalog, resolve the snapshot before composing, and keep resolution failure inside the existing post-commit Run failure path.
- [ ] Push the branch, run XcodeGen build and all relevant tests on macOS CI, then review the diff for scope and secrets.

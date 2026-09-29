# S5-07 Card Delete and Undo Implementation Plan

> Execute serially with behavioral RED before production code. Stage 5 device acceptance follows the owner's whole-stage review.

**Goal:** Delete the selected App Space Conversation with an upward gesture or equivalent accessibility action, preserve its body during Undo, and finalize only after the Undo window.

**Architecture:** A dedicated App Space deletion owner coordinates one selected ID, the Runtime Stop, the persisted lifecycle, and a recoverable deadline. Persistence remains the lifecycle authority; Browse only selects a replacement after a committed deletion. UIKit owns the vertical pan and card animation. The existing Surface, Session, and Runtime retain their distinct owners.

**Tech stack:** SwiftUI, UIKit, Swift Testing, XCTest UI, GRDB, XcodeGen, GitHub macOS CI.

**Spec:** Blueprint `99d30b8` `Design/Zen Agent 开发规划.md` Stage 5 step 7; `Design/Zen Agent App Space、Split 与全局导航.md` §§1, 6, 17–18; `Design/CONTEXT.md` deletion terms. Base `56c8425` (S5-06, PR #23 on S5-05 PR #22). Prior owner decision in `tasks/h1-history-handoff.md`: 10-second Undo window and persistent deadline. `Docs/ADR/0004-card-delete-recovery-clock.md` records the revised cold-start recovery rule.

## Global constraints

- Delete is an upward Current Card gesture; never a normal ellipsis item. New and uncommitted working cards cannot be deleted.
- A nonterminal Parent Run, including suspended and stopping, reaches a terminal cancelled state through the real Runtime before `beginDeletion`.
- During `pendingDeletion`, Messages, Parts, FileAsset references, and Soul binding remain intact; Undo restores them but never restarts a cancelled Run.
- `finalizeDeletion` is the sole body removal point. Repeated and stale requests cannot delete a different selected ID.
- Commit a 10-second absolute Undo deadline with `pendingDeletion` in one transaction. Use a monotonic in-process timer to bound ordinary Undo. If that timer is lost across process restart or foreground recovery, keep the body and require an explicit restore/delete choice; the persisted wall-clock deadline alone cannot authorize body removal. Storage uncertainty keeps the body and exposes retry.
- Current + three predecessors + nearest successor remains bounded. Deleting Current selects its nearest valid neighbor or New.
- VoiceOver/Switch Control can invoke Delete and Undo. Reduced Motion suppresses motion while preserving state changes.
- No Split, Sidebar, Search, Files Workspace, Settings, shader, signing, or new dependency work in this slice. One additive deadline migration is owned by this slice.

## Review focus

1. Selection changes, in-flight browse/Return, repeated swipe, and app scene changes must not redirect a Delete to another ID.
2. Stop failure, cancellation, or read uncertainty leaves the card visible and retryable.
3. A concurrent Run accepted just before Delete cannot leave an active slot after `pendingDeletion` begins.
4. Undo and deadline finalization race on one persisted lifecycle state, with one visible outcome and no empty restored shell.
5. Process restart recovers pending deletion intents without auto-erasing the body; explicit restore/delete resolution is atomic. A surviving in-process timer still completes the original ten-second window.

### Task 1: Persistence and Runtime behavior RED

**Files:** `Tests/ZenAgentTests/AppSpaceDeletionTests.swift`; `App/Persistence/PersistenceStore+Deletion.swift`; `App/Persistence/Migrations.swift`; `App/Runtime/ConversationRuntime.swift` only if a true missing Runtime boundary is found.

- [ ] Test selected durable ID deletion after a terminal Run; assert hidden summary, intact Messages/FileAsset references/Soul, Undo restores full body.
- [ ] Test live and suspended Parent Runs; assert Runtime Stop reaches cancelled terminal state before lifecycle changes; injected Stop failure retains visible state.
- [ ] Test deadline recovery, expired finalization, stale/double Undo and finalization, plus a concurrent Run acceptance race.
- [ ] Publish tests-only branch; read actual compiled macOS behavioral RED. Compilation or fixture errors do not count.
- [ ] Implement the smallest Persistence/read and Runtime coordination boundary; run full macOS CI GREEN.

### Task 2: Selection and native interaction RED

**Files:** `App/AppShell/AppSpaceConversationDeletion.swift` (new); `App/AppShell/AppShellModel.swift`; `App/Workspace/AppSpaceBrowseController.swift`; `App/Workspace/AppSpaceCardDeletionInteraction.swift` (new); `App/Workspace/ConversationSurfaceHost.swift`; `App/Workspace/WorkspaceSurfaceView.swift`; focused unit and UI tests.

- [ ] Test that a committed selected ID disappears, next valid ID takes Current, Undo restores the exact ID, and New/uncommitted cards reject Delete.
- [ ] Test direction lock, under-threshold rebound, over-threshold upward commit, bounded velocity, and stale completion rejection.
- [ ] Test native upward swipe and accessibility Delete/Undo on actual mounted Current, with a stable error/Undo affordance.
- [ ] Publish tests-only compiled behavioral RED before source; implement the owner and UIKit transport without changing horizontal Browse or Surface ownership.
- [ ] Run full macOS CI. Repair all failures without weakening existing keyboard/Lift/browse assertions.

### Task 3: Whole-slice review and delivery

- [ ] Independently review the complete S5-06..S5-07 diff, repair Critical/Important findings with behavioral RED, and rerun full CI.
- [ ] Record exact head/tree, CI run/attempt, counts, remaining device evidence, and PR dependency in `tasks/s5-07-delete-undo.md`.
- [ ] Keep this slice on a stacked PR for the owner's whole-stage review; continue to S5-08 only after exact-tree GREEN.

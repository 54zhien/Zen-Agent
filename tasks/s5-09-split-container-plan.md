# S5-09 Split Container / initial Divider — implementation plan

**Gate:** Start production edits only after S5-08's final exact-tree macOS CI passes. Work on a new branch stacked on draft PR #25. Keep all Stage 5 PRs unmerged for the owner's whole-stage review and later device testing.

**Authority:** Blueprint `99d30b8`, `Design/Zen Agent 开发规划.md` Stage 5 order, `Design/Zen Agent App Space、Split 与全局导航.md` §§1, 8–11, 17–18, and `Design/CONTEXT.md`. Re-read the Blueprint head and real source/test/build state before coding. Names and numeric values in the notes are intent, not API contracts.

**Goal:** Consume a completed `SplitDropIntent` to show a real 50/50 two-Pane workspace. Keep the lifted Conversation's retained native Surface during its convergence, then let it reflow into its Pane. The other Pane starts with a three-across horizontal Conversation Picker (including New); selecting a different history or New installs one independent live Pane. Display the initial Divider in the Drop Guide's place. S5-10 owns free ratio, drag/snap/close thresholds and resize anchor validation.

## Ownership and failure rules

- `AppShellModel` owns the scene's Split arrangement and distinct Conversation Pane/Session/bridge registrations. `RunEventRouter` already keys its Pane registrations by Conversation ID. Split presentation cannot create a second owner for the same ID or cancel an active Run merely because it is hidden or a Pane closes.
- `ConversationSessionStore` currently has one active ID; extend residency for two active Pane IDs without changing existing single-Pane replacement semantics. A closed secondary becomes warm according to its draft/anchor/Run state.
- `SurfaceLiftController` owns native convergence. Its synchronous Boolean callback only preflights acceptance and must not change Workspace geometry. Commit the captured intent through `onConverged` only after native settlement succeeds and the source still matches; cancelled, stale, or failed handoffs keep or restore the original source safely.
- `WorkspaceSurfaceView` owns geometry and visual container; reuse the existing source `ConversationSurfaceHost` identity through the frame change. The second live Pane gets its own host and `ConversationPaneView`, never a second Composer for the source. Picker uses bounded summaries, excludes the occupied Conversation ID, and does not instantiate historical Timelines.
- `NewConversationView` currently wraps the one Full Pane and its navigation sheets. A secondary Pane should render `ConversationPaneView` through its own NavigationStack and bridge while the source retains the original host. Toolbar actions in either Pane must target that Pane's Conversation ID; a source-side New action cannot silently discard the other Pane.
- `ConversationComposerView` currently derives native focus from each Composer's editing state; there is no Workspace active-Pane owner yet. Record active slot only from user interaction/focus, verify keyboard transfer between both live Composers, and ensure Streaming does not steal focus. Tool approvals already live in each `ConversationPaneView` and must stay scoped there.
- Loading a candidate is asynchronous. On read/registration failure, keep the source and Picker, show a retryable error, and never replace a Pane with a partial target. Selection changes invalidate stale load tickets. New creation must be atomic; on failure no duplicate history or ghost Pane appears.
- `ConversationHistoryPreparation` is one serialized worker shared by Full Open, Preview Return and maintenance reload. The second Pane selection must use its existing preparation owner plus a distinct Split selection ticket; cancellation cannot erase another Pane's already committed owner. Navigation races and late maintenance replay need explicit tests.

## Task 1 — arrangement and residency

**Tests first:** Add compiled behavioral tests for source top/bottom, distinct IDs, duplicate rejection, empty/filled slot, active slot changes, and retaining two active Sessions under a zero warm-cache budget. Preserve the existing single-Pane LRU/reconstruction tests.

**Implementation:** Add one small Split arrangement state in `App/Workspace/` and extend `ConversationSessionStore` only as needed. Keep Run and persistence ownership out of the layout state. Test invalid ratio/viewport only if the model actually stores geometry at this step.

**Gate:** Publish test-only RED; then full XcodeGen/app/unit/UI CI for the model change.

## Task 2 — real Pane preparation and live ownership

**Tests first:** Extend `AppShellWiringTests` fixtures to prove that a second Pane loads/registers without evicting the first, both Composer drafts and reading states remain distinct, a duplicate target is rejected, stale or failed loads leave the empty Picker usable, and closing one Pane never stops either active Run or deletes a Conversation.

**Implementation:** Add Split entry/selection/close methods to `AppShellModel` using the existing `ConversationPaneFactory` and `RunEventRouter` preparation ticket. No separate Runtime or duplicate data cache. Keep `newConversation`, Full navigation, deletion and Preview paths safe when Split is active.

**Gate:** Publish compiled behavioral RED before changing model behavior; then full macOS CI.

## Task 3 — retained Surface, Picker and initial Divider

**Tests first:** Extend the native Lift UI fixture and a production-root UI test: a top and bottom Composer drag must reach a real Split; the source's live host and draft survive, the opposite Pane shows three solid cards with New at the right, a source duplicate cannot be selected, and selecting another Conversation yields two distinct accessible Composer/Panes. Test cancellation and an interrupted convergence. Provide an accessibility-equivalent Split entry that does not depend on the drag gesture.

**Implementation:** Connect the accepted S5-08 intent after native convergence. Reframe the existing source `ConversationSurfaceHost`; render an empty Picker or second live host in the other frame. Draw the 50/50 Divider with the initial white Handle and correct horizontal orientation for top/bottom. Keep reading geometry suppressed only during transition; once each Pane is stable, its own scroll bridge resumes. Wire App Space's `Open in Split` action if its target can be prepared safely.

**Gate:** Publish behavioral RED, then run full macOS CI. Review the whole S5-09 diff for duplicate owner, reflow jump, stale async completion and accessibility regressions. Record exact tree/CI and leave physical comfort and performance for the owner's device pass.

## Next boundary

S5-10 adds interactive Divider ratio/weak snaps, close preview and bottom-anchor verification under continuous resize. S5-11 adds iPhone landscape and iPad axis behavior. A static 50/50 Split is not a claim that those later behaviors are complete.

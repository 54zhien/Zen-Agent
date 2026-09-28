# S5-04 — real previews and bounded display ownership

Execute inline, serially, with test-first changes and one fresh whole-branch review.
Base: aeaa05cd7ce6c1e41329da629ed6bdfc54b6e7a5. S5-03 main CI36401064255
passed generation/build,689 Swift Testing/108 suites,20 XCTest units and11UI tests;
one test run start, no test-host restart. Physical Gate A remains open.

Authority: supplied Stage5 plan S5-04 and sections3.2/3.3/3.6; Blueprint596a84d
stage index, CONTEXT, AppSpace, Composer and MessagesData. The supplied plan is
design guidance; subsequent direct continuation authorizes the ordered slices.

## Ownership and contracts

- Lightweight session owns the existing ComposerController and ReadingPositionController;
  no native editor, full timeline or display controller is retained for history.
- A Full Pane owns its live store and scroll transport only while displayed/prepared.
  Single has one stable Full Pane, AppSpace zero; a transition may prepare one.
  Draft/selection/Quote/Attachment and configuration stay with their session.
- Runtime remains the Run owner and persists visible Part changes before publication.
  Detached routing retains identity/checkpoint metadata, never a Pane or token queue.
  Remount loads durable history, resumes unfinished text/reasoning using stable IDs
  and UTF8 offsets, and reconciles approvals through the existing Runtime boundary.
- Global defaults initialize uncommitted new pages, not existing Conversations.
  Cold history uses its latest frozen parent request seed as a compatibility fallback;
  validate availability without rewriting that seed. Durable binding/title provenance
  belongs S5-06. Late target failures affect their captured conversation owner only.
- Specialized summary queries page by pinned/activity/id and bound text payloads.
  Preview reads never instantiate a full Timeline. Read failures expose retry.
  Pure browse/token presentation does not write userActiveAt.
- Stable Card uses a lightweight renderer in the same Surface; return prepares live
  content before the late handoff. Cancelled/stale loads cannot replace a newer target.
  Current plus at most three predecessor previews render; deeper history has no UI host.

## Steps and proof

1. Add existing-API behavioral tests for active detached Pane/live-store release,
   no hidden token repaint, and real persisted A/B/A Draft/configuration/reading-owner
   continuity. Obtain compiled RED in macOS CI before changing production.
   Split session ownership from rendering; remove detached Pane retention; restore
   reading anchor on remount and preserve replay offset correctness. Supplement
   reasoning, completion/failure/cancellation, recovery read failure and actual
   Runtime durable-event interleavings. Obtain full GREEN.
2. Add bounded catalog summary page/window reads and a tiny derived Run status.
   Use runnable new-capability scaffolds or controlled mutations when no prior API
   can execute a RED; never count missing-type compilation as behavior evidence.
   Test100/1000 histories, pinned/ties/cursors/hidden rows, bounded returned text,
   query count/time, corrupt or failed reads, credential-expired versus cancelled
   versus provider failure. Wire the existing recent entry with pagination/error UI.
3. Connect real lightweight previews and preview/live handoff to production Lift.
   Test zero stable-Card Full Panes/native editors, one Single host, finite preview
   window and repeated return/switch ownership. Cover actual native selection,
   reading position, live background completion, failed/stale loads and cancellation.
   Add targeted genuine UI fixtures without production debug controls. Full CI.
4. One fresh-context whole-branch review, one TDD fix pass for Critical/Important,
   record every ruling and deferred Minor. Merge only the exact tested tree; verify
   main CI before S5-05. S5-06 remains behind physical Gate A after S5-05.

## Files and exclusions

AppShellModel, RunEventRouter, NewConversationView; ConversationPaneController,
LiveConversationStore, ConversationTimeline; WorkspaceSurfaceView, SurfaceLiftController
and concrete session/catalog/preview implementations; PersistenceStore summary extension;
corresponding unit/UI fixtures, README, plan and task receipts. SQL remains Persistence.
No schema, dependency, build-setting, Provider/Tool/Prompt changes; no new Send/Stop,
New creation, Pin/Rename/Delete/Undo/Split/Sidebar/Search/Files/Settings paths.

## Rulings and costs

- Ruling: release native editor in stable Card; preserve logical Composer/reading owners
  and restore native selection on mount. Earlier same-editor guarantees describe the
  S5-01/03 retained-host prototype. Cost if wrong: handoff/selection/anchor rework and
  real-device Gate A failure; do not label recreated editor as the same native editor.
- Ruling: rely on the observed persist-before-publication Runtime contract, retain
  small route/active-part metadata rather than hidden token queues. Cost if wrong:
  a future non-durable source needs an acknowledged checkpoint seam before use.
- Ruling: latest persisted parent seed initializes cold historical selection only;
  warm choices remain session-owned and immutable old Run seeds stay intact.
  Cost if wrong: explicit durable binding migration/reselection in S5-06.
- Ruling: summary page/window limits and low-frequency preview refresh are engineering
  budgets, not Apple limits or measured device performance. Cost if wrong: tune query,
  refresh and rendering budgets after real profiling without changing business owners.

Review focus: actual production input paths, release counts and weak references,
session/Run ownership under interleaving, remount offset/part correctness, disclosure
and bounded history queries, honest failure handling, accessibility and cancellation.

## Requested pause boundary

The user requested stopping after the current part during Task2. Finish Task2
bounded summary/status/Recent pagination and obtain real complete CI, then pause
before Task3. Keep this S5-04 branch draft and unmerged; the single fresh whole-
branch review remains after Task3. Current evidence is recorded in the task gate
and draft PR19. Do not start S5-05 or treat CI as physical Gate A acceptance.

2026-09-28 continuation: the owner requested ownership stabilization and confirmed
protected-state overflow. The separate Stabilization plan records the scope.
Task3 remains unstarted; the previous pause is resumed for stabilization only.


## Task3 authorized continuation

The owner said continue after the corrected route: resume Task3, final whole-branch
review and merge only after exact-tree GREEN. Base bc09cf4 is preserved by
codex/s5-04-before-task3. No S5-05 or new persistence/Runtime functionality.
Ruling: use bounded current summary plus its next three keyset predecessors;
new uncommitted page uses an empty preview and retains its session for Return.
This does not create a new-page navigation recovery feature. Cost if wrong:
Card ordering/new-page ownership must be refined before browse, not hidden editors retained.
Task3 starts with runnable inert handoff APIs and production native-editor/weak-owner
regressions; no missing-symbol compilation is counted as behavioral RED.

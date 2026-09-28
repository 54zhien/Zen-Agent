# S5-04 — real previews and bounded display ownership

Execute inline, serially, with test-first changes and one fresh whole-branch review.
Current state: Task1/2/stabilization/Task3 implemented; final review completed,
three Important have genuine RED and corrective source. Exact final CI/integration
receipts are maintained in PR19; dated pending entries below are historical.
Dated pause/unstarted entries below are historical; S5-05 has not started.
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

Task3 behavior RED:4c8a57c5b92e5303f4c901e283329374accffbdd/tree7bc206cc;
CI36432901342 attempt1/job108963450603 generated/built and ran719 Swift
Testing/111 suites with30 issues, all new Preview/weak/native-release assertions.
20 XCTest units and11UI passed; one run start/no host restart. Native UTF16
selection controls passed. Production now replaces the inert handoff with bounded
projections, explicit display detachment, off-main preparation and Router tickets.
Ruling: preparation tickets are invalidated by delivered Run events; only a current
read may register, then the prepared Pane receives subsequent durable events. No
second synchronous timeline reload at registration. Cost if wrong: dirty snapshot
reconciliation needs a transactional read, not another Runtime writer/token queue.

First source486ce68/CI36436119382 attempt1/job108974468409 generated/built
and ran723 tests/111 suites with one fixture failure: direct runtime.send requires
an existing Conversation and waits for completion, so it cannot start the held new
page stream. All30 initial issues passed, including actual native editor release
and UTF16 remount;20 XCTest and12UI passed, one run start/no restart.
Repair the fixture using the production first-Send bridge. Supplementary regressions
cover in-flight cancellation, current-ID open routing, scoped readiness and actual
production Card accessibility Run status. The last three edges retain their current
implementation until compiled behavior RED; not a missing-type failure.
Ruling: a DEBUG-only data seed stays inside Persistence, while the UI fixture uses
the actual Shell/Workspace/Lift path; no raw SQL reaches a View, no schema change.
Cost if wrong: the test seed may need expansion, never a production preview database.

## Task3 and final whole-branch review

Task3 candidate e22783b/tree8b27b0a66a4d31ca9cfb29a840bc9e967ab3969b
passed CI36450865368/job109025033967: XcodeGen/build,728 Swift Testing/111
suites in71.320s,20 XCTest and13 UI in331.669s. Reading frame,offset,anchor
were exactly preserved and the request cleared; one actual start/no host restart.
This was not the final merge candidate: one fresh read-only whole-branch review
of aeaa05c..e22783b found three Important and no Critical or Minor.

One test-first fix pass covers all three findings:
- Missing deep Lazy target: dd085b6 CI36456211134/job109043139387 proves
  Return failure after a valid240-Turn middle-anchor control.1fd4af8
  CI36460120551/job109056361670 passes both deep and short Return with identical
  native frames and pendingnil, but introduces failures in existing keyboard/Lift
  tests. The next candidate removes global scroll-target registration; only missing
  targets use a stable-ID proxy jump followed by content-relative correction.
  Existing visible/keyboard requests keep their original numeric transport.
- Pending Send:1fd4af8 reaches the actual mounted coordinator and its held start
  (count1,awaitingAcceptance), then fails four remount assertions: enabled Send,
  replaced coordinator,duplicate start and lost late error. Session now owns that
  coordinator and protects a pending transaction even if its Draft becomes empty;
  the editor remains releasable. Send/Stop tasks capture the logical coordinator.
- First durable commit while Card:8be78b2 CI36454093408 proves five missing
  current-summary/status assertions. Current-first bounded four-ID refresh passes
  in1fd4af8. The named summary CTE budget excludes concurrent Runtime reads.

1fd4af8 generated/built,730 Swift Testing/111 suites ran81.835s with only the
four genuine pending-Send issues;20 XCTest passed;14 UI ran749.832s with six
failures across existing keyboard/Lift cases. No test-host restart. Hygiene and
Guard passed. Native fixture failures in8be78b2/dd085b6 are not Send ownership
RED. No tolerance or wait was weakened. The final corrective tree must pass all
730 Swift Testing,20 XCTest and14 UI tests before merge. Exact final head/tree,
CI receipt and merge/main verification are maintained in PR19.

Physical Gate A, comfort, Instruments and peak-memory acceptance remain open.
Protected sessions may exceed ten; ten bounds reconstructible warm cache only.
S5-05 browse/snap is not started; S5-06 New/Pin/Rename and S5-07 Delete/Undo
remain later upstream slices. No schema/dependency/build-setting/Runtime policy
change, Preview database, durable Composer, multiwindow or future producer seam.

Deferred production minors: none reported. Preserve the dated historical evidence
below; the current-state paragraph and this section supersede its pending wording.

## Final rulings and costs

- Release stable-Card native editors; retain logical Draft/selection/configuration/
  reading owners. Native recreation is deliberate. Cost if wrong: handoff/selection/
  anchor calibration and physical Gate A repair.
- Keep Runtime ownership and observed persist-before-publication; detached routes
  retain identity/checkpoints, no full Pane/token queue. Consumed visible End is
  not replayed; completed routes reject late events. Cost if wrong: future producers
  need a durable acknowledged checkpoint and unread reconciliation.
- Cold historical configuration uses latest persisted Parent seed; warm choices and
  old immutable seeds survive. Reconstruction rechecks a bounded latest seed rather
  than its initial config. Cost if wrong: S5-06 binding/migration/reselection.
- Page/window/query/refresh numbers are engineering budgets. Ten is reconstructible
  warm-cache budget; protect unsaved/input/config/reading/active Run/pending Send and
  permit overflow; terminal cleanup is opportunistic on successful navigation.
  Cost if wrong: device profiling and a separately specified durable transient policy.
- New cross-page Draft recovery and detach-before-install failure atomicity retain
  baseline behavior; same-page Card/Return is preserved. Cost if wrong: unsent New
  Draft/outgoing display can be lost until the later New lifecycle slice.
- Readiness vocabulary does not implement restoring/migration/error workflows.
  Cost if wrong: later recovery work must be designed before claiming those paths.
- Current plus at most three predecessors; empty New retains its Session. Refresh
  includes current ID even before its first durable commit. Cost if wrong: later
  browse/New ordering policy must be refined through explicit owner acquisition.
- Preparation tickets reject stale/Run-invalidated reads; cancelled bounded reads
  may finish but cannot install. Cost if wrong: transactional snapshot reconciliation
  or resource cancellation after profiling, not another Runtime writer.
- DEBUG persistence seeds and weak mounted-coordinator observation use actual
  Shell/native/Send boundaries. Invalid controls are not RED. Cost if wrong: expand
  real fixtures; no Preview database or artificial coordinator proof.
- Lift geometry is transient; preserve the logical anchor, restore native pixel
  transform and reissue a pending physical target on fresh measurements. The failed
  speculative geometry guard was reverted. Incoming Full may restore before its
  completion. Cost if wrong: first-Full/interruption/device geometry calibration.
- Missing Lazy target materializes once per logical sequence by stable ID; precise
  content coordinates apply only to that sequence. Existing visible/keyboard
  transport remains. Global target registration was removed after real UI failures.
  Cost if wrong: coherent frame/inset calibration under unchanged tests, not loosened
  3-point/10-second position assertions.
- Session owns pending submission coordinator; native View tasks capture only that
  coordinator. Keep its original app/runtime bridge without retaining the Pane.
  Cost if wrong: bridge lifetime refinement when dependency owners change; no Runtime
  transfer, database Session or persistent Composer.
- Independent warm/current-refresh local source followed genuine RED while other
  pinned regressions ran unchanged. Cost if wrong: split/redo proof at shared seams.
- Browse/snap/actionable predecessors, Pin/Rename/Delete/Split/multiwindow and future
  producer/reasoning policy remain later scopes. Optional provider/model/shorter
  excerpts remain future presentation. Cost if wrong: explicit future ownership,
  checkpoint/arbitration and presentation design are still required.
- Device comfort/Instruments/peak memory/Gate A remain unobserved. Cost if wrong:
  physical findings require calibration; CI is not device acceptance.
- Keep chronological evidence and direct live integration status to PR19 rather than
  predicting its final self-referential commit SHA. Cost if wrong: future readers must
  inspect PR/Git/CI; stale historical pending wording is not an authoritative status.

Deferred production minors: none reported by the one whole-branch reviewer.

# S5-04 Stabilization

Baseline: branch codex/s5-04-preview-virtualization, 3d366b8720b069340c6c73b488b9cd045537b5b5.
Upstream: Blueprint stage index, CONTEXT and App Space note fetched live on 2026-09-28.
Task1/Task2 CI36415710769 passed at the historical baseline. Stabilization
passed at bc09cf4/CI36428572524 (716 Swift Testing,20 XCTest,11UI). Task3
has since been implemented and reviewed; see the S5-04 task record and PR19
for final corrective CI/integration. The unimplemented wording below is historical.

## Scope and rulings

- Extract the warm-session dictionary from AppShell into ConversationSessionStore.
  One active presentation session; warm access order belongs to the store.
- Owner confirmed protection of unsaved state and active Runs on 2026-09-28.
  Keep at most ten safely reconstructible warm sessions. Protected sessions may
  exceed this budget. Never stop a Run or discard a Draft to satisfy the budget.
- For retained persisted Conversation sessions, protect Draft text/selection/
  references/attachments/presentation, composing or
  dragging input, non-bottom reading mode and changed configuration. Cold history
  configuration still uses the existing persisted parent seed. No new persistence.
- Extract Pane construction/configuration/bridge assembly to a concrete factory;
  retain existing AppAssembly Runtime ownership and captured failure identity.
  Lookup/preparation does not activate a Session. Register the replacement first;
  then commit the active owner and evict. Failed navigation keeps the outgoing Pane.
- Convert presentation content availability into a typed status; preserve existing
  ConversationCardStatus Run semantics. Database corruption remains data-layer
  evidence mapped at the UI boundary. Do not pretend that a migration is underway.
- No new UI feature, Runtime/schema/dependency/build-setting changes or multi-Scene
  scaffolding. Blueprint excludes V1 multi-window. Unseen active Runs stay Runtime-owned.
- Ruling: the supplied route names conflict with upstream. Preview/live handoff is
  existing S5-04 Task3; upstream S5-05 is browse/snap. Stabilization alone cannot
  close or merge S5-04. Cost if wrong: premature integration of retained Full editors.

## Serial verification

1. Real existing Shell API RED: weak safe-session release under 15 history opens,
   with an unsaved Draft control, then successful cold/warm reopen.
2. Implement store, safe LRU and PaneFactory. Supplement LRU/ties/replacement,
   protection across all input/reading/configuration state and active Run transitions;
   use real Shell/Router integration for lifecycle failures. Full CI GREEN.
3. Typed presentation availability preserves corruption indicators and status mapping;
   existing bounded SQL/cursor/Recent tests remain required. Full CI GREEN.
4. Fresh read-only review of stabilization scope and the unresolved S5-04 boundary.
   Any Important fix requires behavioral RED then full GREEN. Update PR/task receipts.

## Evidence ledger

- RED candidate f1153a3b154a81c59dc5cd415a1f8f2f5e3c34a1, CI36424865908 pending.
- Local first test edit normalized mixed line endings; corrected before connector
  publication. Remote candidate changes exactly 26 lines. Original local commits
  remain preserved on the local branch; execution checkout follows the remote RED.
- CLI authentication unavailable. Use authorized GitHub connector for publication;
  git read-only OpenSSL fetch works. Never log credentials.

- Authoritative behavior RED: 3e969343454d29a2e8a7a048c519b70f37f67841,
  CI36425228738 attempt1/job108937855204. Generation/App build passed;
  711 Swift Testing/110 suites ran with exactly two issues: weak safe-session
  release and release after terminal routing. Unsaved Draft/configuration/reading
  controls passed.20 XCTest units and11UI tests passed; no test-host restart.
  Initial f1153a3 run was superseded/cancelled and is not counted as RED.
- Ruling: do not compare against initial configuration; re-read the latest Parent
  configuration via the existing bounded summary window on successful departure.
  Read failure/corrupt summary protects the owner. Cost if wrong: retained owners
  can exceed ten until a later successful navigation proves reconstruction safe.
- Task1 source: concrete Store plus safe LRU, no tombstone dictionary for evicted
  entries. Factory preparation peeks; successful Shell commit sets active order.
  Wall-clock timestamp ties use committed sequence order. Eviction is checked
  on successful navigation; terminal routing alone does not trigger a cache sweep.
- Supplemental direct-store tests cover tied-clock LRU, all transient Draft/input
  branches, uncertain reconstruction and changed durable configuration. They use
  newly introduced APIs and are supplemental, not independently claimed RED.
- Typed readiness is published in Recent presentation; data-layer corruption
  evidence and existing Run Card status stay separate. Restoring/migration/failed
  vocabulary does not manufacture a migration or a new Preview UI flow.

## Independent stabilization review

One fresh read-only review of3d366b8..97e8869 found no Critical/Important issue.
Minor wording about Draft protection is clarified above. The reviewer did not
execute Swift/macOS CI; final full CI remains mandatory. This review covers
stabilization, not the premature whole-S5-04 gate before Task3.

Rulings for the review's declined scopes:
- Retained persisted Conversation sessions are protected under eviction pressure.
  An uncommitted new page has no durable row and no existing return path; its
  baseline navigation behavior stays unchanged. A cache of unreachable pages is
  not recovery. Cost if wrong: leaving an unsent new page still discards its Draft;
  separately specify the New lifecycle before S5-06 implementation.
- newConversation detach-before-install atomicity remains baseline behavior,
  excluded from this pass. Cost if wrong: a new-page install failure loses the
  outgoing display; review that failure contract when implementing New.
- S5-04 Task3 preview/native-editor handoff, actual native selection remount and
  zero stable-Card editors remain unimplemented. Cost if wrong: merging now would
  advertise virtualization while still retaining the old Full editor prototype.
- Physical comfort/memory/Gate A remain unobserved. Protected owners may exceed
  ten; eviction is opportunistic on successful navigation, not a strict total
  memory cap. Cost if wrong: device profiling may require a separately designed
  durable Draft/reading snapshot policy.
- Restoring/migration/failed enum vocabulary does not implement UI workflows.
  Cost if wrong: claiming those paths would misrepresent recovery functionality.

Candidate97e8869 generated/built successfully in CI36427796710 before the final
review/scope documentation checkpoint. Do not use a superseded run as full GREEN.
The exact final checkpoint and its complete CI receipt are maintained in PR19;
no merge/S5-04 closure is authorized by this stabilization-only evidence.

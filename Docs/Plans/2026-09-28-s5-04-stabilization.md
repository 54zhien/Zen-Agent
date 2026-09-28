# S5-04 Stabilization

Baseline: branch codex/s5-04-preview-virtualization, 3d366b8720b069340c6c73b488b9cd045537b5b5.
Upstream: Blueprint stage index, CONTEXT and App Space note fetched live on 2026-09-28.
Task1/Task2 CI36415710769 passed at the baseline. Task3 has not started.

## Scope and rulings

- Extract the warm-session dictionary from AppShell into ConversationSessionStore.
  One active presentation session; warm access order belongs to the store.
- Owner confirmed protection of unsaved state and active Runs on 2026-09-28.
  Keep at most ten safely reconstructible warm sessions. Protected sessions may
  exceed this budget. Never stop a Run or discard a Draft to satisfy the budget.
- Protect Draft text/selection/references/attachments/presentation, composing or
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

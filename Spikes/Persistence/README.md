# Persistence Spike

Throwaway. This directory exists to answer one question and then be deleted:

> **Which persistence engine does Zen Agent use — SwiftData or GRDB?**

The decision and its rationale are recorded in
[`Docs/ADR/0001-persistence-engine.md`](../../Docs/ADR/0001-persistence-engine.md).
When that ADR is resolved, keep the invariant regression tests (see "Deleting this
spike" below), then delete the rest of this directory and the
`PersistenceSpikeTests` target from `project.yml`.

## Why this is a spike and not a data layer

No product entity, repository or migration lives here. Stage 0 must not start on
`AgentRuntime`, `ToolRuntime`, Conversation UI or anything else that would be
built on top of the engine choice — if the engine changes afterwards, all of it
gets rewritten. The only code allowed here is the minimum needed to run the
scenarios below.

## How it runs

A macOS logic-test bundle, not an iOS simulator test: the semantics under test
(transactions, constraints, migration, recovery) are platform-independent, and
macOS logic tests run roughly an order of magnitude faster in CI. No host app.

`EngineWiringTests.swift` is already here and only proves that both engines build
and run in CI. It also probes the single most decision-relevant mechanism — the
conditional uniqueness constraint — before the full scenarios are written.

## Findings so far

Established by CI, not by reasoning about the APIs:

| Finding | Evidence |
|---|---|
| The generated project builds and both test bundles run on `macos-26` / Xcode 26 | CI run 35421484359 |
| GRDB resolves as an SPM dependency and works in this target | `GRDB opens an in-memory database and round-trips a row` — passed |
| **GRDB rejects a second active run via a partial unique index** | `GRDB can express conditional uniqueness via a partial unique index` — passed |
| SwiftData works in this macOS logic-test target | `SwiftData builds an in-memory container and round-trips a row` — passed |
| SwiftData permits multiple NULL slots (terminal rows coexist) | `SwiftData permits multiple NULL slots` — passed |
| **SwiftData's `#Unique` did not reject a second occupant of a non-NULL slot** | `SwiftData unique constraint permits multiple NULL slots` — failed at the occupied-slot assertion |

The last one is open, and it is the one that decides scenario B. "Did not reject"
leaves three materially different possibilities — the constraint is absent, the
second row was accepted as a duplicate, or the first active run was silently
overwritten — and they call for different workarounds. The probe now reports which
one occurred and separately tests whether a **non-optional** slot changes the
answer.

Do not settle this from memory of SwiftData's documented behaviour. The probe
exists precisely because that is the failure mode this project has already been
bitten by twice.

## The scenarios

Each scenario runs against **both** engines, driven through one shared harness so
the two are compared on identical operations rather than on two separately
written test suites. A scenario passes for an engine only if the engine satisfies
it *without* application-level locking that would not survive a process crash.

### A — Atomic send commit

One transaction creates the frozen User Message, the Parent Run, and the frozen
request-config seed. Either all three exist or none do. Then: kill the process
between "message written" and "run written" and assert no half-state is readable
on restart.

*Fails if:* the engine cannot express the three writes in one transaction, or
requires application-level ordering that a crash can interleave.

### B — Double-send race

Two concurrent sends into the same Conversation. Exactly one Parent Run may end
up active; the other must fail cleanly — not "both succeed and we reconcile
later".

*Fails if:* the engine can only express *unconditional* uniqueness. The
requirement is "at most one **non-terminal** run", which is conditional. Both
candidates need the nullable active-slot + unique index workaround, so this
scenario is really asking whether that workaround holds under real concurrency
and survives migration. `EngineWiringTests` already checks the single-threaded
half of it.

### C — Tool dispatch crash

A write-capable ToolCall persists an `executing` checkpoint, the external action
happens, the process dies before the terminal result lands. On recovery the
engine must let us distinguish *"prepared but never dispatched"* from *"possibly
dispatched"*. Only the first may be re-dispatched.

*Fails if:* the engine cannot durably separate those two states, or the
checkpoint write is not ordered before the external call in a way a crash
respects.

### D — Migration interruption

Old schema → new schema, interrupted mid-migration, restarted. Data must survive
and the migration must be re-runnable without duplicating or destroying rows.

*Fails if:* migrations are not transactional, or cannot be resumed.

**Known trap:** SwiftData migration tests must run on a real store, not just in a
Simulator — a Simulator that rebuilds deletes the store, so migration code may
never execute and the test goes green without testing anything.

### E — Delete / Undo

`visible → pendingDeletion → (undo | finalize)`. During the undo window the
Conversation body must be fully intact — undo has to restore the *complete*
conversation, not an empty shell.

*Fails if:* the only way to hide a row also discards its content, or the engine
cannot express "hidden but not yet purged".

### F — Tombstone

Delete a Conversation that still holds an `indeterminate` ToolCall. The body goes;
a minimal tracking record for that external operation must remain, and must not be
swept away by cascade.

*Fails if:* the engine's delete rules cascade unconditionally, or the tombstone
cannot be made to outlive its former parent.

### G — Streaming write pressure

Many deltas arrive; the design is buffer → coalesce → periodic snapshot → final
save. Measure how many store writes the engine actually performs and whether it
blocks.

*Fails if:* the engine forces a write per delta, or snapshot writes block
progress. This is the scenario most likely to be engine-specific rather than
merely configure-and-go.

## Decision criteria

Beyond the seven scenarios, record for each engine:

- **Concurrency model fit.** Strict Swift 6 concurrency is on project-wide.
  GRDB 7 documents itself as requiring Swift 6 but Swift Package Index builds
  still show Swift 6 data-race diagnostics, and GRDB recommends refactoring
  `Record` subclasses into structs before enabling strict checking. Whether that
  friction is acceptable is part of the decision, not a footnote.
- **Whether the conditional-uniqueness workaround is native or bolted on.**
- **Migration story**: re-runnable, interruptible, expressible without losing
  type safety.
- **What the app must give up** to use it.

The losing engine's cost is recorded too — if the choice is later revisited, the
reasons should already be written down.

## Deleting this spike

**Not** "pick an engine, then `rm -rf Spikes`". The invariants this spike proves
are the ones the app depends on forever, so the tests outlive the spike:

    A–G all pass
      ↓
    ADR-0001 accepted (with the losing engine's cost recorded)
      ↓
    real persistence skeleton exists
      ↓
    the invariant tests below are migrated into the real test target
      ↓
    CI still green
      ↓
    delete the disposable implementations

Tests that must survive as permanent regressions, because they encode product
invariants rather than engine comparisons:

- **active Parent Run uniqueness** — the conditional-uniqueness constraint and its
  behaviour under concurrent send.
- **Atomic send** — no readable half-state after a crash between the message write
  and the run write.
- **Indeterminate recovery** — a possibly-dispatched write is never re-dispatched,
  and the two `executing` sub-states stay distinguishable.
- **Migration** — re-runnable after interruption, without dropping data.

The engine-comparison scaffolding (the harness protocol, both implementations,
the A/B comparison itself) is what gets deleted.

## Layout

| File | Purpose |
|---|---|
| `EngineWiringTests.swift` | Proves both engines build and run in CI; probes conditional uniqueness |
| *(to come)* `SpikeHarness.swift` | Protocol both engines implement, so scenarios are shared |
| *(to come)* `SwiftDataHarness.swift` | SwiftData implementation |
| *(to come)* `GRDBHarness.swift` | GRDB implementation |
| *(to come)* `ScenarioTests.swift` | Scenarios A–G, run against the harness |

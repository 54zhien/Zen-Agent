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

## How results are recorded

Every scenario is scored on three dimensions, not one. "It works" is not the
question; *what is holding it up* is:

| Dimension | Question |
|---|---|
| **Correctness** | Does it satisfy the invariant? |
| **Enforceability** | Is the invariant held by the database, or by application discipline? |
| **Testability** | Can the failure path be reproduced and verified reliably? |

These matter more for Zen than lines of code. A guarantee held by app discipline is
a different class of guarantee from one held by the database — it holds only as long
as every call path remembers the discipline.

**A missing capability is not a safety claim.** If a failure mode cannot be
injected — because the framework owns the flow — that is a finding about
**controllability and observability**, not evidence that the engine is unsafe. Those
are three separate layers and collapsing them would be overreach:

    does it support the capability
      ↓
    can the failure mode be injected
      ↓
    can the recovery behaviour be verified

## Findings so far

Established by CI, not by reasoning about the APIs.

### Scenario B — active Parent Run uniqueness

Same eight-claimant race, same `ClaimOutcome` scoring.

| | SwiftData | GRDB |
|---|---|---|
| Correctness | **broken** — `won=3` | **holds** — `won=1` |
| Enforceability | application discipline only | **database constraint** |
| Testability | good — the race reproduces | good |
| Mechanism | fetch-then-insert inside `transaction {}` | declared partial unique index |

SwiftData's three winners each read zero, inserted, and committed — with **no error
raised**. `ModelContext.transaction` does not serialise the check against the
write, and the type exposes no isolation-level control to ask for otherwise.

The failure shape matters: both SwiftData runs produced *exactly three* winners. Not
a stable failure — a race that will sometimes look like a pass.

### Scenario A — atomic send

Split into two different failures: **A1** the transaction body fails and must roll
back; **A2** the process dies with work in flight and must leave nothing behind.

Every A2 result is gated by a **negative control** that commits one half and stops —
proving the probe can see a half-state. Without that, "no half-state occurred" is
worthless, because the probe might simply be blind to one. This is the same mistake
that made D3 look like it worked while D1 and D2 were failing for an unrelated
reason.

| | A1 rollback | A2 no residue | control |
|---|---|---|---|
| GRDB | ✅ | ✅ (positive half only) | ✅ |
| SwiftData | ✅ | ✅ | ✅ |

A tie on atomicity.

**One counter-intuitive injectability find.** GRDB refuses to leave a transaction
open:

    GRDB/SerializedDatabase.swift:131: Fatal error:
    A transaction has been left opened at the end of a database access

A `fatalError`, so it took the test bundle down and CI re-ran the suite. GRDB is
being *safe* — the dangling state cannot be reached by accident — but the same guard
means "killed with a transaction open" **cannot be injected through its API**. So
GRDB's A2 establishes the positive half plus the control, and the crash-mid-transaction
case rests on SQLite's atomic-commit guarantee as a design claim, not as something
this probe verified.

The asymmetry runs the unexpected way: **the engine that can be tested here is the
one with fewer safeguards.** That is a testability fact, not a safety verdict.

### Scenario C — crash window

| | SwiftData | GRDB |
|---|---|---|
| Correctness | **holds** | **holds** |
| Enforceability | database (durable marker) | database |
| Testability | good | good |

A tie. `prepared` and `dispatching` stay distinguishable after the writer is gone,
on both. The earlier concern that SwiftData might refuse to reopen its own store was
unfounded.

### Scenario D — migration

Split three ways, because "migration works" is not one property:

- **D1** normal V1 → V2: data survives, schema changes
- **D2** repeated open: no re-application, no duplication
- **D3** interrupted: rolls back, resumes cleanly, leaves no half-applied schema

| | D1 | D2 | D3 correctness | D3 diagnosability |
|---|---|---|---|---|
| GRDB | ✅ | ✅ | ✅ rolls back, resumes | ✅ cause surfaces |
| SwiftData | ✅ | ✅ | ✅ store stays usable, data intact | ❌ **cause is discarded** |

Two SwiftData findings, both established by CI rather than assumed:

**1. Adding a non-optional attribute fails the migration outright.**

    Cannot migrate store in-place: Validation error missing attribute values on
    mandatory destination attribute
      entity=Note, attribute=pinned

Existing rows have no value for it and SwiftData will not invent one — a
constructor default does not help, because the schema needs a value for rows that
already exist. This is the shape that breaks an app update: the store will not open
afterwards. The working shape is an optional attribute plus a `didMigrate` backfill.

**2. A migration failure discards its cause.**

The injected error does propagate into CoreData and does abort the migration — the
CoreData log reads `returned error PersistenceSpikeTests.MigrationInterrupted (1)`.
But SwiftData wraps it in a generic container error with `_explanation: nil`, so the
caller cannot read it. An app cannot distinguish "my migration code threw" from "the
schema is wrong" from "the store is corrupt".

That is **diagnosability**, not safety. The migration does abort and the store does
stay usable — the loss is in what you can learn afterwards. It matters here because
a failed migration means the user cannot open the app at all.

SwiftData runs migrations implicitly when a `ModelContainer` initialises, and the
public surface (`VersionedSchema` / `SchemaMigrationPlan` / `MigrationStage`) offers
no handle for stepping or pausing one. So its D3 injects a thrown error inside a
migration stage — a **controlled** failure, not a process killed mid-write.
Likewise, SwiftData exposes no way to ask which schema version a store is at, so
"rolled back to V1" cannot be asserted there; the check is the weaker but checkable
"still opens and still holds its data".

Reading any of this as "migrations are unsafe" would be overreach. The three layers
are separate: the capability works, the failure mode is only *partly* injectable,
and the recovery behaviour is verifiable but the cause is not readable.

### Declared-constraint semantics

| Finding | Evidence |
|---|---|
| The generated project builds and both test bundles run on `macos-26` / Xcode 26 | runs 35421484359 / 35422701520 |
| **SwiftData's `#Unique` upserts rather than rejects** — the first row is silently overwritten | `rows after save: [active-2/slot=c1]` |
| **A non-optional slot upserts the same way** | `rows for slot c1: [active-2]` |
| GRDB rejects a second occupier via a partial unique index; terminal rows coexist | passed |

Upsert is a defensible design for a merge-oriented store; using it as an exclusivity
constraint is a category mismatch. For an invariant whose requirement is "the loser
fails cleanly", it is worse than no constraint — it destroys the row it was meant to
protect.

### Still open

- **The serial-owner escape hatch.** The blueprint permits "transaction, serial
  owner, constraint, or equivalent". An in-process actor serialising Run creation
  would satisfy it — but the guarantee stops at the process boundary: it does not
  cover app extensions or a second process, nor any write path that bypasses the
  owner.
- **Scenarios A, E, F, G** are untested on both engines. B plus C plus D is the
  decisive group; C is a tie, so a selection now would rest on one scenario.

Do not settle any of this from memory of the documented behaviour. The probe exists
precisely because that is the failure mode this project has already been bitten by
twice.

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

## Scenario weights

The seven scenarios do **not** carry equal weight, and "1 of 7 done" is the wrong
way to read progress:

| Weight | Scenarios |
|---|---|
| highest | **B** uniqueness · **C** dispatch crash / indeterminate · **D** migration / recovery |
| medium-high | **A** atomic send · **G** streaming write pressure |
| medium | **E** delete / undo · **F** tombstone |

Read the results accordingly: if GRDB is clearly more natural and stronger on
**B + C + D**, prefer it even if SwiftData writes less code for E and F.

**A is not part of that group**, and a tie there does not offset B. A is
single-transaction atomicity; B is uniqueness across competing writers. Different
problems, and the second is the one the Runtime invariant depends on.

### Scenario G — streaming write pressure

Assertions cover what is stable and decidable; timing numbers are printed, not
asserted. Thresholds on a shared CI runner are flaky, and the decision does not turn
on them — if both engines are fast enough, being slower is not grounds for rejection.
Reporting keeps the evidence without inventing a verdict from noise.

| assertion | GRDB | SwiftData |
|---|---|---|
| persisted total correct after batching | ✅ | ✅ |
| writes collapse (600 deltas at batch 50 ≠ 600 writes) | ✅ | ✅ |
| terminal flush is what survives a reopen | ✅ | ✅ |
| a read completes while a write commits | ✅ | ✅ |

A tie on every control property. Both collapse to **12 writes**.

Measurements (`[G]` lines in the CI log):

| | GRDB | SwiftData |
|---|---|---|
| writes | 12 | 12 |
| wall | 26.6 ms | 69.1 ms |
| write P50 / P95 | 1.68 / 3.56 ms | 4.21 / 7.72 ms |
| store bytes | 20 KB | 139 KB |
| read P95 | 0.15 ms | 0.20 ms |

Speed is not a disqualifier here — 12 writes at single-digit milliseconds is far
inside "fast enough" on both. The store-size gap (6.8×) is the one figure worth
carrying forward, because CoreData's per-row overhead compounds as Runs, ToolCalls
and Parts accumulate.

### Progress

| | B | C | D | A | E | F | G |
|---|---|---|---|---|---|---|---|
| GRDB | ✅ | ✅ | ✅ | ✅ | — | — | ✅ |
| SwiftData | ❌ known defect | ✅ | ✅ | ✅ | — | — | ✅ |

## Layout

| File | Purpose |
|---|---|
| `EngineWiringTests.swift` | Proves both engines build and run in CI; characterises declared-constraint semantics |
| `ScenarioTests.swift` | The A–G scenarios, both engines, same assertions |
| *(to come)* `SpikeHarness.swift` | Shared harness protocol, if the scenarios grow enough to need one |

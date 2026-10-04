# S5-13 Search — preparation record

The owner authorized all remaining Stage 5 code before whole-stage review and
device testing. This slice follows the completed S5-12 full code gate; no
Search production source has been published yet.

## Intent and source boundaries

Blueprint global navigation section14 and the development plan require title
Search, lightweight thumbnail/title results and an input/exit control above the
keyboard. Plain exit preserves the original Session, draft, reading state and
Run; successful result activation opens the target Resting. Search is a Workspace
overlay and does not own Runtime or create a second live Pane for thumbnails.

Persistence owns bounded visible-title matching and stable pinned/activity/ID
keysets. Reuse the existing 512-character input bound, Unicode whitespace
normalization, manual-title override and56-character displayed title. Matching,
projection and highlighting must agree. Literal query input remains parameterized;
`%`, `_`, backslash and quotes are text. Do not search the full first Message,
fetch all rows into a Swift filter or introduce a schema/search-index migration.

The pinned GRDB7.11.1 source verifies pure `DatabaseFunction` registration on
a read connection and its Sendable closure:
https://github.com/groue/GRDB.swift/blob/v7.11.1/GRDB/Core/DatabaseFunction.swift
The existing `ZenDatabase.readAsync` delegates scheduling/cancellation to GRDB.

The Search model owns query generation, debounce, bounded paging, retry feedback
and pending selection cancellation. Query replacement, exit or disappearance
invalidates pending publication and cancels the selection task. Activation uses
the existing `AppShellModel.openConversation`; recheck durable visibility at
owner commit after its asynchronous history read. Preserve the outgoing owner
until success, including its active Run. Failure or cancellation keeps Search
and the original owner intact.
Apply Search's Resting presentation inside that existing activation transaction,
before publishing the target Pane. A post-await callback alone is insufficient:
Workspace's owner-change reset can dismiss/cancel Search before it runs, while a
warm target may retain an earlier editing presentation. Other activation paths
retain their existing presentation policy.

Workspace owns overlay routing and native focus capture. Capture the actual
retained Composer responder before hiding/suppressing it: didEndEditing clears
logical focus. A plain exit queues restoration for that same Pane/host/Window,
consumed only after native mounting, usable layout and input reenablement. Owner
replacement, inactive scene or native modal invalidates it. No timed sleep or
Task.yield is a substitute for native readiness.

Keep feature routing/focus composition out of the already large Workspace root.
Remove temporary Recent only from a live Full Single once Search is reachable;
retain New's Recent and per-Pane Split Recent. Startup remains the approved New
screen with first durable Conversation creation at Send.

## Prepared evidence plan

Publish existing-API Search UI behavior tests for compiled RED only after the
S5-12 full gate. Current disabled Search must fail its actual availability check,
without invoking nonexistent feature APIs to manufacture a compile failure.
Future persistence/model tests accompany implementation after that real RED.

Regressions cover native focus/Editor identity on plain exit, draft preservation,
keyboard placement and actual target activation; literal Chinese/ASCII queries,
SQL-like punctuation, bounded fallback/manual Rename, malformed first parts,
deleted lifecycles,120-row stable paging and controlled late/cancelled reads.
After targeted GREEN, remove the temporary profile and pass full generation,
build, unit/UI and actual Pad gates. No merge or device acceptance is included.

## Local test-profile evidence

The fixed `search-red` profile is confined to `codex/s5-13-search` and selects
the complete unit target plus the two existing-API Search UI cases. Main and an
absent profile remain full. Infrastructure RED was1 error in9 local profile
tests (unknown mode); the minimal fixed-mode handler passed all9. This is local
profile validation only, not compiled Search behavior evidence. Future API unit
drafts stay outside the test-only publication.

## Verified predecessor and initial publication

S5-12 full source gate is remote9218e8c7fc9e5a11baa53bafda4787fb962768c0 /
tree6c1b9095f933b111590025a6d0aadd9a6bfe3bd1. PR37180642485 and
push37180640443 both passed generation/build,873 Swift/132 suites,20 XCTest,
46 phone UI (one expected Pad-only skip,zero failures) plus one actual Pad
axis case each. No retry/test-host restart. Its closure documentation travels
with this subsequent test-only slice; the predecessor receipt stays exact.

The initial publication adds the fixed profile and two actual Search UI tests,
with no Search production source or future-API unit files. Compiled behavior
RED is pending; do not claim Search implementation or completion from these
test drafts or local Python checks.

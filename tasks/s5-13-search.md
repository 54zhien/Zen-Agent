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

## Compiled behavior RED and first implementation

Test-only remote bbe818a5c4745dcce881a1a7cb359b3e8508cac7 / tree
949232cda900fac663f701e7f9afe1c85405ad9a compiled in push37182466455
and PR37182479638. Both phones passed873 Swift/132 suites and20 XCTest;
both actual Search UI cases failed only `Sidebar Search destination is
unavailable` (two assertions/two cases). Actual Pad axis passed in both runs.
No missing-symbol compile failure, retry or host restart. Phone jobs are
111377645856 /111377694343; Pad111377645852 /111377694304.

The first implementation shares summary title/first-text semantics with a pure
literal SQL function, filters before bounded keyset LIMIT and runs reads through
GRDB's async owner. Query generation owns and cancels debounce/read/selection
workers. WorkspaceOverlayCoordinator owns overlay focus and selection lifetime;
retained native input/AX visibility follows the observed navigation reference.
Plain exit queues the actual editor responder and waits for mounting, input,
layout, same owner/window and active scene. Successful Search applies Resting
inside existing Open before publishing the Pane. A fresh lifecycle read after
history/wiring rejects deletion committed during a stale WAL snapshot.

Regressions accompany implementation: literal SQL-like characters, Unicode and
bounded fallback/manual titles,120-row paging/deleted states; controlled late
reads, cancellation and pending selection; real native responder identity and
owner invalidation; warm-target Resting/drafts and a second WAL connection that
commits deletion during the actual history snapshot. Only the live Full Single
Recent toolbar entry is removed; New and Split retain their existing entry.
Targeted compiled GREEN and full source gates are still pending.

## First compiled implementation result and native Rail correction

Remote28173228b76654d944d939a358297d2f8d434eb9 /tree74a4c855d84e9b095b250a46a980b8df3316323d
compiled in PR37183488294 and push37183485523. Both phones passed886 Swift
in136 suites and20 XCTest, including the real second-WAL stale-deletion and
native-focus unit regressions. The two Search UI cases in each run still failed
before overlay entry. Raw AX receipts distinguish this from the initial RED:
Search was enabled, but its hittable wait failed. Inspection found that the
untranslated full-screen SurfaceHitView could consume the exposed empty Rail
strip. This was a concrete native defect, not yet the complete UI diagnosis.
Keep the assertions; do not tap by forced coordinates.

Add a real UIWindow/child-controller hierarchy regression with an underlying
UIButton. Ordinary Full hit testing now rejects points outside the Surface's
actual visible translated bounds; interior/closed Full and existing Card crop
routing remain covered. Search also gains the specified route fade (static for
Reduce Motion) and a bounded actual summary thumbnail. Compiled UI GREEN remains
pending. PR actual Pad111380593291 passed130.947s; push111380590388 failed
70.626s because Xcode application launch timed out before axis execution.
Phone111380593292 /111380590431 each had2 UI failures and no restart/retry.
Source review of the initial21-file implementation found no P1/P2 blocker;
actual UI nevertheless found this missing native hit-routing boundary.

## Window safe-area correction after retained hit-test GREEN

Remote f59f382d37691846b928b938a70b1caa1ec4e3ad / tree
fa85ed1f86326267fdeb37e815299e228f3e7c36 built in PR37184413977 and
push37184411320. Both phones passed887 Swift /136 suites and20 XCTest,
including the new real native hit-test regression, but Search UI still failed
its unchanged native hittability gate. Both actual Pad jobs passed.
The downloaded PR xcresult video shows Search at the very top of the display,
overlapping the status bar. The full-viewport GeometryReader deliberately ignores
container safe areas and therefore provides zero control Insets. Native strip
pass-through alone cannot fix the status-bar activation region.

The existing WorkspaceLayoutObserver now reports the actual UIWindow.safeAreaInsets.
Navigation controls and their Surface translation share that source; retained
host bounds, Lift transform and keyboard layout remain independently owned.
Search UI additionally asserts its button is below the scene status bar before
the existing real hittability/tap gate. This correction still needs compiled
targeted and full gates; no forced hit point, retries or weaker assertions.

The c7901e6 window-inset source built and passed887/136+20 units on the
push phone111386290158. Both UI cases stopped in the new placement assertion:
the app AX tree exposes no StatusBar element, so reading its frame throws before
the existing hittability gate. Keep the geometric assertion and compare against
the native diagnostic's actual UIWindow.safeAreaInsets.top instead; require a
nonzero portrait receipt. This is observed native geometry, not a forced tap or
a fixed device number. The retained stream regression also now uses the actual
WorkspaceOverlayCoordinator.select wrapper, then checks dismissal, continued
provider output, durable completion and the outgoing unsent draft.

## Stable Rail composition correction

Remote d93671ae3e6367e5fb465ab54a916a183acaa104 /tree
315d5f32738f69f70d73982fd2caf4033b59310e passed888 Swift/136 suites and
20 XCTest on push111388007436, including the actual held-stream regression.
Both Search UI cases passed the required nonzero Window-inset and below-status-bar
geometry assertions, then failed native hittability. Actual Pad111388166950
and111388007465 passed120.401s and111.491s respectively.

The complete SwiftUI content still occupies the full viewport above the Rail,
even though its native Surface rejects the exposed strip. Give only the stable,
settled, finite-width Rail precedence over that content layer. Drag/settlement
composition and the overlay's higher layer remain unchanged. Continue to use the
actual enabled/hittable/button tap and native focus/draft tests; log the observed
button frame for future triage. Targeted GREEN and the full gate remain pending.

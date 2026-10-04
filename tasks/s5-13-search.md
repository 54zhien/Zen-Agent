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

## Reachable Search and retained responder correction

Remote f46a267aa8a828b7ce6b3725c01aa5466adafb84 /tree
ccb06f28f61c56f6c4f301f409b8daf59b667f0c built in PR37186895810
and push37186892661. Phone111390700067 /111390663097 each passed888
Swift/136 suites plus20 XCTest and ran2 Search UI cases with4 failures.
Their actual enabled/hittable/tap gates now passed; result activation and
Resting were reached. Both actual Pad111390700034 /111390663065 passed.
No test-host restart/retry was used.

One UI assertion measured52pt from TextField AX to Keyboard AX instead of the
actual visible keyboard boundary. The downloaded xcresult video shows the input
bar adjacent to the visible keyboard and a prediction region above the keys.
Retain the28pt limit and actual keyboard presence requirement, but compare
against a DEBUG same-window UIKit keyboard-layout-guide receipt, logging both
AX and native frames. Product Search layout is unchanged; the new receipt must
confirm the geometry before this assertion can pass.

Plain exit also failed native focus/keyboard restoration. Source review found a
real readiness race: reattaching the retained content runs Composer mounting and
layout while its outer host is still hidden; clearing that hidden gate did not
retry the queued token. Recheck the same queued capability after native host
visibility opens; the existing bridge retries after input reopens. A composed
Window/Surface regression covers both event orders, same editor and same draft.
Targeted and full compiled GREEN remain pending.

## Native keyboard GREEN; focus-token gate diagnostic

Remote f6cf3e7070dfef8b16e10d32f4de0324636b621a /tree
0ebe7ee61d2b252f3ff2a78d69d2f61bd3a014a7 built in PR37188330393
and push37188328173. Phones111395028655 /111395035226 both passed889
Swift/136 suites plus20 XCTest, including both composed native gate order cases.
Both actual Pad111395028634 /111395035240 passed. No restart/retry.

Result-activation UI passed in both phones. Native receipt was identical:
input maxY531, UIKit keyboard top539 (8pt gap), AX keyboard top583.
This confirms the44pt AX measurement difference while retaining the28pt
requirement and the unchanged Search layout.

Plain exit still failed in both (2 UI cases,3 assertions failed each). The native
receipt shows the same retained editor with a pending, valid restoration token
and visible/interactable ancestors. The native visibility race unit regression
passed but does not resolve every end-to-end readiness condition. Do not infer
that the existing editor must be replaced. Add exact early-return/last-become
receipts to the existing consume path and print them after its bounded focus wait.
This diagnoses input, editor mount/visibility, ancestor, Window/scene, presented
controller and actual becomeFirstResponder failure without bypassing a guard.
Targeted/full GREEN remain pending; Files production has not started.

## Exact native visibility diagnosis and correction

Diagnostics-only remote aafa5928f34c46411f498ebab00adee378b282a2 /tree
5e4cdbe394b73d33186dcb3454a6773908ef8fbf, push CI37189688294:
XcodeGen/build passed;889 Swift tests/136 suites passed108.510s and20 XCTest
passed. Result selection UI passed53.798s. Plain exit failed50.301s with3
assertion failures. Both the immediate and settled receipts identify the last
blocking guard as hiddenAncestor:UIKitPlatformViewHost wrapping the native
ConversationSurfaceHost. At the settled receipt that ancestor is actually
visible, but no native callback has retried the valid pending token. The actual
editor has input permission, is visible, remains in its Window and can focus.
This disproves the unconfirmed Search first-responder-decline hypothesis.

WorkspaceSurfaceView applies SwiftUI opacity(visible ? 1 : 0) after the native
setWorkspaceVisible update. The native controller already owns the hidden gate
and detaches inactive content. Remove the redundant SwiftUI opacity gate;
retain native visibility, input/AX admission and physical Session/editor owners.
The existing plain-exit UI case remains the actual failing regression; no delay,
forced editor tap, new editor or keyboard geometry relaxation is added.

Push actual Pad passed111.663s. PR actual Pad failed133.393s with one bounded
waiter assertion; it is retained as a failure, not silently retried or called a
pass. The correction still needs targeted and full build/unit/UI/Pad receipts.
Verification ruling: restore the full profile immediately for this correction.
The one-line visibility-owner change crosses all physical Surface paths, so the
required full phone and actual Pad gate is the concrete remaining verification.
It includes both unchanged Search cases plus Sidebar/Split/Return regressions.
A separate targeted-only pass is not a prerequisite for that broader required
gate. The intermediate1f7e41f publication is superseded if still running; it is
not claimed as a passing gate. No test expectation or cancellation gate is relaxed.
Read-only review confirms every surfaceIsVisible path supplies native visibility;
Return proxy visibility remains owned by its existing native controller.
## Full visibility correction receipt — focus is subsequently revoked

Full-profile remote4f6bb23457b150b066e0e8c367f3b17b82add239 /tree
e74d5cd9662e297ad7d81cf15474454b030909a0 completed both phone gates:
PR37190500300 /phone111401532852 passed generation/build,889 Swift/136 suites
90.719s and20 XCTest.48 UI with one expected Pad-only skip had3 failures in
1223.299s, all in plain Search exit. Result activation passed49.270s.
Push37190498183 /phone111401535960 passed889/136 in93.561s plus20 XCTest;
48 UI/one expected skip/3 failures1142.033s, again only plain Search exit.
Result activation passed51.526s. Other phone UI paths passed.

Both native exit receipts now show overlayFocusReason=restored, token consumed,
but actual focused=false and logical Resting. The hidden wrapper correction
therefore removed the first blocker, and a subsequent native or bridge event
revokes the successful restoration. This is not proof of one specific revoker.
Add bounded DEBUG-only native event receipts for restore/begin/end editing,
bridge Resting resignation, suppression resignation and keyboardDidHide; preserve
all focus behavior and both UI expectations until the exact event is observed.

Push Pad passed124.056s. PR Pad failed91.667s before axis execution, with an Xcode
app-launch timeout. Prepare each chosen simulator with simctl bootstatus before
the single xcodebuild test call; print current CLI help, retain all retry/restart
and skip checks, and verify the real command in CI. Recreate the fixed Search
profile for this narrow diagnosis; final full profile remains required.
## Native Search responder handoff — candidate correction

Diagnostics-only remote68da769280405f750248ff3ce45778c054d533ce /tree
59a80d3a6ce4fe6a610ac8bebf2da8eb6159bba7 completed:
PR37192410854 /phone111407221290 passed889 Swift/136 suites85.379s and20 XCTest.
Result UI passed57.156s; plain exit failed51.579s with3 unchanged assertions.
Push37192407493 /phone111407208603 passed889/136 in78.501s and20 XCTest;
result UI passed58.856s, plain exit failed45.994s with3 unchanged assertions.
PR Pad111407221216 passed100.643s; push Pad111407208608 passed78.274s.
Current simctl bootstatus CLI help/readiness completed before each single test.

Both traces are queue -> restoreAttempt -> didBeginEditing -> restoreSucceeded
-> didEndEditing -> keyboardDidHide. Neither bridgeRestingResign nor
suppressionResign appears. Thus neither a stale bridge false nor keyboardDidHide
initiates this particular revocation. Search's scene-level declarative focus
cleanup after its close is the remaining source-supported ownership candidate;
the trace alone does not identify the UIKit caller of didEndEditing.

Replace Search's FocusState input with its own native UITextField boundary.
Close waits for that field's real didEndEditing acknowledgement before dismiss
and retained-Composer restore; an unfocused field completes immediately once.
Outgoing updates and dismantle resign only that query field, never the Window.
Keep the existing plain-exit UI RED unchanged. Add an actual UIWindow and
UIHostingController integration test covering query editing, end-before-restore,
representable update during the outgoing fade, dismantle, and original responder,
identity and draft preservation. This candidate is not yet a passing result.

Add a separate existing-API native regression for a global software-keyboard
hide while the actual Composer remains first responder. Current Host behavior
is preserved for this behavioral RED; do not infer focus loss from visibility
or call the keyboard notification the cause of the observed earlier trace.
New regression APIs accompany production, not a missing-symbol RED publication.
## Native query receipt and separate keyboard-owner RED

Candidate remoteceb873a67974be02f1afbad48752327245ef4055 /tree
 de4f37dafed63efa841c61450a7f1974257dd27e built in both phone/Pad jobs.
Push37193601502 /phone111410769664:20 XCTest passed,892 Swift/136 suites
failed88.394s with2 issues. The native keyboard-hide regression recorded
focusEvents=[false] while the actual editor remained first responder (behavioral
RED). The hosting integration fixture did not mount its query input; this is a
fixture failure, not evidence of a missing input in the actual app.
Both Search UI cases passed: result61.299s, plain exit49.023s,zero failures.
Native exit keeps the same editor focused=true, Editing, with actual keyboard.
Actual input-keyboard gap remains8pt. Push actual Pad passed72.260s.
PR37193603795 /phone111410770102:20 XCTest passed,892/136 failed93.024s with
the same2 issues. Both Search cases passed58.524s and34.827s,zero UI failures.
The whole candidate gate is failed, not GREEN. Both phones have one Swift test
start and no test-host restart; no retry or assertion relaxation was introduced.

Fix the confirmed separate owner bug: keyboardDidHide may clear logical focus
only after this editor has actually lost native first-responder ownership.
Real didEndEditing remains authoritative; hardware/other-editor keyboard hiding
cannot revoke a currently valid editor. Full dismissal/Sidebar/Split gates remain
required to verify this distinction.

Repair hosting fixture containment: keep Composer under its ordinary parent
UIViewController and mount Search's actual hosting controller as a child/sibling.
Mount the query from the initial hosting root; use actual native become/responders
for the handoff, and require the subsequent SwiftUI update to really occur.
The end-to-end UI already verifies automatic Search entry focus and actual close.

Read-only review follow-up: cancel pending query callbacks on disappearance or
detach, bind close to a unique overlay presentation id, and prevent an old
acknowledgement from dismissing a reopened Search. Same-presentation replacement
rearms an unacknowledged close; completed/cancelled presentations stay terminal
through their outgoing fade. Cover missing actual delegate acknowledgement,
replacement's fresh close, stale field callbacks, and old overlay-id close.
New Files asynchronous callbacks must also capture their presentation id; the
coordinator's no-argument compatibility call is not Files routing evidence.
## Native-owner correction receipt — only fixture retirement assumption fails

Remotea0a49942361b86a37533caf55f8fc442db1a612a /tree
2972e72befe5c9457a8940c9f07d0ab44d7a7da6 completed both targeted gates.
PR37194517456 /phone111413505325:20 XCTest passed;894 Swift/136 suites
failed100.101s with only1 issue: hosting query.window was still non-nil after
its outgoing transition. The keyboard-hide protection, real query editing,
end-before-restore, query update, pending-close replacement and stale overlay-id
cases passed. Search UI passed60.578s and34.893s (zero failures95.472s).
Push37194515408 /phone111413596721:20 XCTest passed;894/136 failed105.123s
with that same1 issue. Search UI passed60.063s and35.500s (zero failures95.562s).
Both have one Swift test start and no restart/retry. PR actual Pad passed70.504s;
push actual Pad also passed. The whole targeted result remains failed.

Repair the fixture's overconstrained lifecycle premise, not product focus.
SwiftUI can retain an outgoing native view in the Window after dismantle.
Assert the real production dismantle receipt instead: onText must be non-nil
before removal and is cleared only by SearchQueryInput.dismantleUIView. Drive
actual hosting layout and wait for that callback clearing, while retaining
original editor.isFirstResponder, identity and exact draft assertions. The real
Workspace UI continues to require that Search input disappears; no UI gate is
relaxed and no product behavior changes in this follow-up.

Restore the full profile now. All required production Search/native-owner paths
passed their targeted tests; the full Workspace gate is the concrete remaining
risk check for normal keyboard dismissal, Sidebar, Split and Return. A second
identical targeted-only run is not a prerequisite for that required broader gate.
Full generation/build/unit/all phone UI/actual Pad evidence is still mandatory
before Files production. Physical-device acceptance remains separate.
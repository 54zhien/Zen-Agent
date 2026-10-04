# S5-14 Files — implementation and retained evidence

This authorized slice follows the completed Search full code gate. The Files
Workspace source gate is still open. The implementation candidate follows the
compiled existing-API behavioral RED recorded below.

Blueprint navigation section15 and data sections6–7 require a real single-level
catalog, native import, immutable preview/export and guarded removal. Workspace
presence does not authorize Agent reading or enable incomplete attachment Send.

Reuse ManagedFileStore and the persistence layer. Its operation lock is already
static and process-wide across instances. Copying, hashing, disk enumeration,
publish/cleanup and database work must not block the presentation actor. Keep
picker security-scoped access for the complete worker operation, current backup
and file-protection behavior, stable asset identity and immutable version bytes.

The existing protectedAfterWrite observer supports a genuine behavior RED:
cancel the actual worker after copy, release it into verification and require
CancellationError with no version metadata or published blob. Add cancellation
checks during hash verification and before publication/metadata commit; preserve
an already committed asset. Rollback must recheck fingerprint references under
the existing lock and must itself finish despite cancellation.

Persistence owns bounded metadata pages and atomic durable-reference checks.
The Session store owns removal reservations across both Panes, warm drafts and
the real Session-owned submission coordinator's pending attachment snapshot.
Only matching submission completion releases that snapshot. Acquire a tokenized
reservation on the owner actor and hold it until database removal completes.
Durable historical Message versions, including non-current versions, stay intact;
fresh orphan checks must preserve other assets sharing the same digest.

The catalog model owns cancelable picker/file operations and readable failures;
preview/export use verified immutable bytes. Missing/corrupt bytes remain a
readable metadata error. No new binary payload is copied into Message text and
no Stage6 Tool policy is added. Reuse the overlay ownership/focus boundary from
Search; entering or leaving Files does not stop a Run.

Prepared tests cover actual overlay/picker cancellation and draft restoration,
post-copy cancellation, shared bytes, historical versions, transient references
and pending Send navigation. Publish compiled behavioral RED, implement, review
and pass full macOS build/unit/UI/actual Pad gates before Settings. No merge,
IPA or physical-device acceptance is included.

## Verified source and native API preflight

The existing v6 schema has no currentVersionID foreign key cycle: fileAssetVersion
belongs to fileAsset with CASCADE, while messageAttachment protects both asset
and historical version with RESTRICT. Remove the asset only inside a writer
transaction after checking any attachment that names the asset or one of its
versions; then perform fresh shared-fingerprint orphan cleanup under the existing
ManagedFileStore lock. A durable refused removal must retain all versions.

Session protection reads draft references plus the real submission coordinator's
pendingAttachmentsSnapshot. The snapshot is cleared only by matching acceptance
or rejection. Reservation acquisition and completion run on MainActor, with a
token held through the off-actor metadata transaction. Future attachment producers
must check that reservation before accepting an attachment; the current app has
no producer that adds managed files to Composer and this slice does not enable one.

Preview/export create a verified immutable temporary copy while holding the
existing file operation lock. The native Quick Look/export-picker lifetime retains that
copy, so catalog removal cannot make a displayed preview lose its backing bytes.
Copy/hash work stays off MainActor and cleanup is scoped to the owned copy.

Current Apple documentation verifies UIDocumentPickerViewController's
forOpeningContentTypes/asCopy initializer and balanced security-scoped URL access.
The worker owns any successful scoped access until copying/verification finishes;
picker cancellation performs no import. A false startAccessing result alone is
not proof that an already sandboxed picker copy is unreadable.
Sources: https://developer.apple.com/documentation/uikit/uidocumentpickerviewcontroller/init(foropeningcontenttypes:ascopy:)
and https://developer.apple.com/documentation/foundation/url/startaccessingsecurityscopedresource().

## Read-only preparation review follow-up

The existing-API post-copy cancellation regression is the intended compiled
behavior RED. Future removal/reservation APIs remain untracked drafts, not
compiled evidence. Review added a real caller-cancel/blocked detached writer
case: duplicate reservations stay refused until the writer exits. An integration
draft routes actual ManagedFileStore bytes and a warm Session pending snapshot
through reserved removal; stale rejection cannot release it. The native picker
cancellation draft now asserts the empty catalog remains empty.

Before closing this slice, add an actual held Runtime stream through Files
entry/exit, and exercise real preview/export controls and immutable export bytes.
Those paths still need production wiring and compiled evidence; preparation is
not Files completion.

The actual asynchronous picker-import worker must carry cancellation through
the metadata writer boundary, including time spent waiting for that writer.
Do not assume a Task-local cancellation check survives an arbitrary Dispatch
queue hop. A small owned cancellation signal can be checked inside the same
create-asset transaction before/after inserts; an already committed asset wins.
Cancellation cleanup rechecks durable fingerprint references and finishes despite
cancellation. Add a gated writer regression when this actual path is wired.

Prepared native UI coverage now includes actual Quick Look dismissal and an
actual exporting Document Picker for a dedicated managed test asset. A prepared
immutable-copy test removes the catalog asset and invokes cache cleanup while
the native presentation lease still owns its bytes. The cache cleaner must
exclude leased copies; it must never remove managed assets or Session drafts.
Catalog pagination drafts require bounded metadata, stable cursors and no
duplicated identities. These new-API drafts remain uncompiled preparation.
The existing-API cancellation RED runs its control body on MainActor while the
real detached worker is held after copying, avoiding test-thread-pool starvation.

CI readiness follow-up: Search diagnostic68da769 already prepares each chosen
simulator with simctl bootstatus before the single test invocation, prints
current CLI help, and retains all restart/retry and skip guards. Both actual
Pad jobs passed. The final Search full code gate remains open; Files production
starts only after it closes. This is simulator readiness, not a test retry.
Export ruling: follow the actual navigation note section15 and the plan's native
Document Picker import/export boundary. Use forExporting/asCopy with the verified
owned copy, retaining that copy through picker dismissal. Quick Look preview is
separate. The earlier activity-controller preparation is corrected before any
Files production publication; native UI verifies picker entry/cancellation and
service tests verify exact export-source bytes. Actual external file-provider
completion remains a physical-device observation, not fabricated CI evidence.
Apple reference: https://developer.apple.com/documentation/uikit/uidocumentpickerviewcontroller/init(forexporting:ascopy:)

Cancellation-test liveness preflight: the existing-API post-copy RED now cancels
its actual import Task synchronously from the existing copy-completion observer.
A short startup latch binds the real Task before copying; no file lock is held
waiting for MainActor control. Held-import model tests still require checking
all other MainActor ingest fixtures: AttachmentSendTests currently performs
several synchronous ingests. Before publishing Files tests, move those fixture
imports into an awaited detached worker without changing their assertions, so
a parallel fixture cannot block MainActor while a held import awaits close.
This is prepared test liveness, not Files compilation or runtime evidence.

## Existing-API behavioral RED publication

Search full tree81dfd8c48e3cb17a453749432fc0f6272bbdcb24 passed both full
phone/actual Pad CI runs37195522196 and37195524247. Files follows that closed
source gate. Publish only the existing-API post-copy cancellation test and the
basic Sidebar Files/import-picker-cancellation/focused-editor-restoration UI
case. The fixed files-red profile runs all unit tests and Files UI; the actual
Pad job remains required. New removal, catalog, model and presentation APIs are
still uncompiled drafts and accompany production only after behavioral RED.

Prepared owned-cancellation metadata coverage verifies detached cancellation
handoff and no asset/version commit. Its pre-call signal does not prove GRDB
queue admission; implementation review must separately confirm that cancellation
checks run inside the same writer transaction, before any insert and before
commit. No stronger queue-wait evidence is claimed.

## Initial Files test build failure — not behavioral RED

Remote9bb7aa5cb0b231af5632dec996b0e1f217cfa6a0 /tree
7b4288291b03f89760adf5aa4c84788f73325c1f published the test-only candidate.
Push37197419656 phone111422065597 and actual Pad111422065604 both failed
test compilation: FilesImportCancellationTests line23 called semaphore.wait
directly in an async Task body, forbidden by the current Swift6 SDK. No test-run
start or behavioral assertion receipt exists; this is not behavioral RED.

Replace that startup latch with a buffered AsyncStream event. Bind the actual
Task to the cancellation receipt before yielding its startup event; the worker
awaits that event asynchronously, then copies through the unchanged production
ingest path. The synchronous after-copy observer still cancels the same actual
Task. No production Files change accompanies this test compilation repair.

## Compiled existing-API Files behavioral RED

Remote1904846fb2153bdff7f7623444b4a3e1aadbfbdc /tree
338816ded688c14fabbd4c10be2c84eb44c91c37 built successfully.
PR37197983305 /phone111423714583:20 XCTest passed;895 Swift Testing in137
suites ran84.199s, with only3 issues in the actual after-copy cancellation case:
no CancellationError, version metadata persisted, and the blob persisted.
Its cancellation receipt passed, proving the same actual import Task was cancelled.
The Files UI case failed25.191s because Sidebar Files is unavailable. Exactly
one Swift test-run start and no host restart. Both actual Pad jobs passed.
This is behavioral RED, distinct from the preceding test compilation failure.
Approved Files production may now proceed with the prepared service/Session/model
tests, native preview/export UI and held Runtime regression.


The push run37197981216 /phone111423712574 reproduced the same three cancellation
issues:895 Swift Testing in137 suites78.693s;20 XCTest passed. Files UI failed
27.909s because its Sidebar destination is unavailable. One Swift test-run start,
no restart or retry. Actual Pad axis passed in PR job11142371459376.329s and push
job11142371250080.192s, one real test each.

## Complete Files candidate — native CI pending

The bounded metadata catalog uses keyset pagination (maximum50 rows per page).
Removal checks all historical durable attachment references in its transaction.
The real retained Session drafts and Composer pending snapshots protect their
asset IDs; removal reservations last through actual writer and blob cleanup.
No attachment producer or incomplete attachment Send capability is enabled.
Runtime remains the Run/Streaming/Approval owner.

The async Workspace model owns its real detached worker and cancellation signal.
Security-scoped import covers the whole copy operation. The owned signal reaches
inside writer transactions before and after mutations. A completed metadata commit
wins; cleanup drains using fresh shared-fingerprint references even after cancellation.
Existing attachment fixtures now ingest off the presentation actor with assertions
unchanged, avoiding actor blocking on the process-wide file lock.

Native Quick Look and document export use verified immutable, protected copies
excluded from backup. Copies survive catalog deletion and cache clearing from
another store instance while leased. Redirected cache namespaces are refused.
Presentation IDs and one-shot native callbacks reject stale completion. Closing
Files restores the original editor identity, draft and native focus.
Quick Look editing is explicitly disabled using the documented delegate API:
https://developer.apple.com/documentation/quicklook/qlpreviewcontrollerdelegate/previewcontroller(_:editingmodefor:)

Candidate tests cover paging, missing/corrupt bytes, shared blobs, historical and
pending references, cancellation, reservation lifetime, cache leases and symlinks,
off-main import and a held Runtime stream. Native UI covers real managed text in
Quick Look, the export document picker, import cancellation and editor restoration.
The writer-cancellation test does not prove GRDB queue admission; in-transaction
checks are source evidence until native execution supplies the remaining behavior.

Read-only review found no concrete P1/P2 blocker before compilation. This is not
GREEN evidence. Actual XcodeGen/build/unit/Files UI and Pad CI are required, followed
by removal of the temporary files-red profile and the complete Stage5 UI gate.
Local YAML and ten profile guards passed. The managed build-settings guard could
not execute locally because Ruby is unavailable; its real CI result remains required.
PR31 stays draft and unmerged. External provider completion, device comfort,
VoiceOver and memory acceptance follow the owner's whole-stage review.


## First production compilation receipt

The e6222c5 /tree39b2375 candidate failed PR phone111431964899 during app build:
QLPreviewControllerDelegate's SDK requirements are nonisolated, while the
Coordinator's editing and dismissal implementations inherited MainActor. No
behavioral GREEN is claimed. The repair keeps the constant disabled editing
response nonisolated, and explicitly hops the dismissal callback onto MainActor
without transferring the native controller or weakening global concurrency checks.
Swift's primary migration guidance explains nonisolated protocol requirements:
https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/commonproblems/
The callback still captures the presentation ID through the existing close guard.
Actual compilation, unit/native UI and full gates remain pending.


## Parallel fixture ownership follow-up

Delegate repair ce8bf9a /tree99e69c compiled the app. PR actual Pad
111432602953 passed its real axis case89.784s, zero failures/skip; phone
unit/Files UI was still executing when the next fixture repair was published.
Source inspection found a concrete test deadlock risk: the import-success model
test synchronously verified its blob on MainActor while the parallel held-import
test could own the global file lock awaiting MainActor cancellation. The success
test now verifies and reads the same actual managed bytes in a detached task
under withVerifiedBlob. Assertions and production operations are unchanged.
This source finding is not a claimed runtime failure trace or GREEN receipt.
Both native runs and the full gate must complete on the repaired tree.

## Native Files and Pad receipt on e9fcbb0 / tree54ace7c

PR37201667292 phone111434611596 passed20 XCTest and911 Swift Testing
in141 suites77.331s. Push37201664506 phone111434578595 passed the same
unit counts84.411s. Each had one Swift test start and no host restart.
Files import cancellation and original native editor restoration passed in both.
Actual Quick Look displayed the managed text and closed through native Done.
Native export appeared, but its cancellation query failed twice per phone run.
Decoded actual xcresult AX hierarchy shows Cancel is an Other element rather
than Button. The corrected query uses that native subtree and also requires
its actual Save button. Remove the duplicate SwiftUI export identifier; the
UIKit picker retains the identifier. No export behavior is changed.

Actual Pad PR111434611517 failed only horizontal resizing; push111434578716
also observed transient source AX absence after axis selection. PR diagnostics
show both native hosts visible, no input lease, and a hittable divider, but no
UIPan callback and unchanged50 percent ratio. No production cause is established.
Add bounded DEBUG diagnostics for handle identity, received native touches,
actual XCTest screen point, live overlay/preview and both native host visibility
flags. Keep gesture configuration, drag coordinates and all assertions unchanged.
The candidate is not GREEN; Files full gate remains open.

## Native cancellation delivery and full candidate

On e58561d /treed339979, PR actual Pad111439496208 passed154.928s and
push actual Pad111439487577 passed97.996s, one real case each, zero skip/failure.
Both now recorded real Pan callbacks, same handle identity, released leases,
and changed horizontal width. Only diagnostic code changed; this does not
establish a cause or fix for the earlier intermittent Pad input loss.

PR phone111439496242 passed911 Swift/141 suites128.179s and20 XCTest;
push111439487584 passed911/14176.533s and20 XCTest. Import/focus passed.
Both export cases found native Save and Cancel, then failed only the final
Composer count. The actual log shows semantic Cancel tap computed {-1,-1};
the following Files-close tap also computed {-1,-1}. Existence alone had allowed
the covered underlay to be tapped before real native dismissal.

Use the actual native Cancel control's center coordinate, require the picker
actually disappear and Files Close become hittable, then require Files disappear
and the native Composer return. No control/assertion is skipped or app-owned
picker dismissal introduced. Remove files-red now so the repaired candidate
runs all Stage5 units/UI plus the separate actual Pad gate. All results remain
pending on this new tree; Settings production is still waiting for the full gate.

## Review P2: post-commit cleanup state — existing API regression

Read-only review found that removeUnreferencedAsset commits metadata removal,
then throws if orphan enumeration/deletion fails. FilesWorkspaceModel refreshes
only a successful .removed result, leaving an already-deleted row on screen.
Add an existing-API regression using the actual FileManager injection: ingest
actual bytes off actor, load the catalog, refuse only that blob's deletion,
then run the actual model removal. Require real metadata/version deletion,
retained bytes and a recorded cleanup refusal, but an empty refreshed catalog
and explicit committed-removal feedback. Unblock cleanup and verify the existing
fresh-reference orphan operation subsequently removes exactly those bytes.

Only tests/record/profile change in this candidate. Restore files-red for a
compiled behavioral RED and native export dismissal receipt; the preceding full
candidate is superseded by this concrete review finding and is not GREEN.
No production repair before the compiled behavioral receipt. Afterwards restore
the complete source gate before Settings.

## Compiled cleanup RED and scoped repair

Push37204609305 /phone111443393359 compiled and ran912 Swift Testing in141
suites76.199s. Only the new committed-removal case reported two unit issues:
stale model.items and missing explicit committed-removal feedback. Actual
metadata/version deletion, cleanup refusal, retained bytes and subsequent
fresh-reference cleanup all passed.20 XCTest passed; one test-run start.
PR actual Pad111443424481 passed87.243s, one real test. Native export coordinate
input still did not dismiss the picker, so that path remains under investigation;
its stronger disappearance/hittability assertions exposed five downstream failures.

Repair wraps only the cleanup error after actual metadata commit as a safe
assetRemovedCleanupPending condition. Removal always reloads authoritative rows.
The Files model preserves pending cleanup and provides an explicit off-actor
retry through existing removeUnreferencedBlobs; its real worker still drains
before isWorking/ownership is released. The model regression also retains another
actual FileAssetVersion and verifies model retry deletes only the orphan, leaves
referenced bytes intact, and clears pending state only after complete success.

Native export receives additional test-only AX/frame and actual cancellation
callback diagnostics, with input and assertions unchanged. No speculative picker
production repair or native-dismissal success claim. Targeted native and complete
source gates remain required before Settings.

## Cleanup GREEN and native presentation investigation

Remote531dc11debb2172262e134445f7324cd0a45905f /tree
562b5486daf7d74ad2425188bc06556e998d6de5 passed all912 Swift Testing in141
suites in PR phone11144650953794.855s and push11144650441092.843s;
20 XCTest passed in each, one Swift test-run start and no host restart.
The committed-removal/refusing-FileManager regression now passes, including
catalog refresh, explicit pending cleanup, real retry and retained referenced bytes.

Native export failed in both phones. Before input, Cancel was an AX Other at
(263.7,92,36,36), not hittable; tapping its reported center left the actual picker
visible and Files Close covered. No documentPickerWasCancelled receipt appeared.
The preceding decoded native AX evidence shows that same coordinate opens the
remote file browser's More menu; import Cancel was sometimes only1pt wide.
This rules out treating the earlier element-type query repair as a dismissal fix.

Test the concrete presentation hypothesis: the current picker is embedded directly
as SwiftUI sheet content, while Apple's current UIKit example presents the actual
UIDocumentPickerViewController with present(_:animated:completion:).
Replace only that adapter with a conditional background Presenter bound to the
existing presentation UUID. Keep Quick Look's sheet. Coordinator retains the
immutable export source, coalesces delegate/interactive cancellation, and publishes
the captured result only after actual native dismissal. Dismantle invalidates
callbacks and retains the owner through presentation/dismissal completion.
Read-only lifecycle review found no P1/P2; actual compilation and native behavior
remain pending. Files UI input and its complete dismissal/restoration assertions
are unchanged for this presentation experiment.
Apple: https://developer.apple.com/documentation/uikit/providing-access-to-directories

Actual Pad push111446504479 passed86.556s. PR111446509517 failed only its
greater-than50pt resize assertion: actual Pan began, ended normally and applied39pt,
with both native hosts visible, the same handle and released input leases.
The drag's two XCUICoordinates reference the moving divider; XCTest resolves that
element repeatedly while synthesizing input. Apple's coordinate documentation
explicitly says locations depend dynamically on the referenced element's frame.
Anchor the same100pt input to the stable app viewport using the captured handle
center, retaining velocity, duration and all ratio/identity/restoration assertions.
This is a test-input hypothesis, not a production gesture fix or Pad GREEN claim.
Apple: https://developer.apple.com/documentation/xcuiautomation/xcuicoordinate/screenpoint

The targeted native candidate and subsequent complete Stage5 suite must pass on
their exact trees before Settings production begins.

## UIKit presenter experiment result and style diagnostic

Remote6210e695ba2976a937ad5dc31533c360455972a7 /tree
6e1649ce9de0bc8a4fa3a274646928fc19f174fa compiled. PR phone111449938378
passed912 Swift/141 suites79.477s and20 XCTest; actual import/focus passed40.687s.
Push111449920109 passed912/141100.679s and20 XCTest; import/focus passed52.655s.
One Swift test-run start, no host restart. Both export cases failed actual Cancel
and retained-owner restoration. Its AX Other frame/hittability was identical to
before. The real remote More Button occupies exactly that reported Cancel frame;
remote Save is a distinct native Button. Direct UIKit presentation did not fix it.

Both real Pad cases passed with stable app-coordinate endpoints: PR111449938350
96.614s and push111449920030109.718s, each one actual test, zero failure/skip.
Both recorded an85.5pt horizontal width change, real Pan, same handle/editor
identities and preserved independent ratios. Earlier failed input receipts remain.

Next diagnostic tests the actual document picker's inherited modal style under a
DEBUG-only UI-test flag: overFullScreen retains the presenting views, unlike
fullScreen, so it avoids intentionally removing the retained Workspace hierarchy.
The same actual native Cancel input and all dismissal/focus assertions remain.
This flag is an experiment, not a production fix or sufficient full-gate evidence.
Remove it and publish the accepted production behavior before any source closure.
Explicit native screenshots and xcresulttool attachment export on failed runs
provide rendered evidence; the export step is diagnostic and cannot change a
failing build/test into success. Its current CLI help is printed in the real CI.
Apple: https://developer.apple.com/documentation/uikit/uimodalpresentationstyle/overfullscreen
# S5-14 Files — preparation record

This authorized slice follows the completed Search full code gate. No Files
Workspace production source has been published yet.

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

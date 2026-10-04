# S5-15 Settings — preparation record

This authorized slice follows the Files full code gate. Formal Settings
production source has not been published yet.

Files FULL is now closed on remote `c9f6e2a`,tree `c66db812`,push37222392865
and PR37222395611. Branch `codex/s5-15-settings` starts from that source.
First publication adds only existing-API credential provisioning regressions
and two actual Sidebar Settings UI cases. No new Settings API draft is included.
The branch-fixed settings-red profile runs all unit tests and Settings UI;
compilation and behavioral failures must be observed before production changes.
This targeted profile is not the complete Settings source gate.

## Compiled behavioral RED and first implementation

Local `909458e`,remote `d7f243c648deafc66f1efe2be17aa69889462b42`,
tree `155d1c05a3b96e9bfacfcb6f6a7b6929c2e6e165`,draft PR32 targets Files.
Push37225526901 / phone111504293120 and PR37225544000 / phone111504345019
both generated and built the app and test targets, passed20 XCTest, and ran915
Swift/142 suites. Each had precisely one Swift issue: failed fresh metadata
publication leaves generation1 secret bytes. Published and unreadable metadata
retention regressions passed. Both actual Settings UI cases failed because the
Sidebar destination is disabled (2 tests/2 failures); no missing-symbol RED.
Push Swift92.871s/UI60.144s; PR Swift71.329s/UI41.338s. Each retained exactly one
Swift test-run start and no host restart. Logs are retained in the handoff folder.
Push actual Pad111504293156 passed; PR Pad111504345002 failed an axis-menu
readiness expectation at the existing helper line83 (185.818s). This independent
failure is retained and must be resolved or pass on the complete candidate before
a source gate can close; it is not erased or assigned an unproven cause.

Implementation starts only after the PR's compiled behavioral failures were
observed; the same-source push finished with matching failures during that work.
Adds formal Settings models/pages and native responder ownership; captured New
initialization, future-default scope, account CAS, immutable Soul version/disable,
real storage/lease behavior and persisted menu preferences use existing owners.
The full third Startup/New UI case is now wired to an empty real AppShell fixture.
Production and new-API tests remain unverified until actual candidate CI.

### First candidate feedback and focused acknowledgement RED

Local46c7def/remotea6d95a0e/treef63f83d5 compiled in both targeted runs.
Push37227274903 and PR37227279248 generated/built and ran927 Swift/146 suites.
Two issues were retained: the old caret test still expected literal black rather
than the authorized semantic label color; the new Storage fixture's Cache URL
omitted its directory hint and was refused by the existing managed-path guard.
All other unit cases, including credential compensation, account CAS/ownership,
Soul disable/version conflicts and future-New scope, passed. Actual Pad passed
in both runs. Three UI cases failed: Startup queried an absent Send button although
unconfigured Composer policy hides it; both Soul paths reached the native input
but the pushed page lacked the root's Close toolbar. No completed gate is claimed.

Correct the fixture/obsolete expectation and preserve Startup's unavailable-Send
assertion as absent-or-disabled, then require actual enabled Send after configuration.
Every Settings destination now publishes the same overlay-owned native Close
toolbar; there is still one responder/close owner. No picker or native input skip.

Read-only review found a separate acknowledgement gap: a tracked Settings field
with a cleared first-responder flag closed before its matching didEndEditing.
Three model-event regressions exercise pending matching acknowledgement, foreign
field rejection, cancellation and a presentation with no owned field. These use
real UITextField values with controlled delegate-event ordering; they are not
on-device timing evidence. Publish the existing review-red unit profile before
changing that production branch, then restore Settings UI scope and FULL later.

Blueprint navigation section16, the Prompt/Soul baseline and development plan
define grouped Settings: models/services, appearance, Agent, files/storage,
data/privacy and About. Agent lives only under Settings; Soul is currently live.
Unsupported Memory, Skills, MCP, tools/subagents and environment editing do not
receive empty controls or switches that pretend to affect requests.

Reuse Provider instance revision checks and the credential service. Existing
ProviderSetup is a creation/credential subflow, not complete account management.
Global model defaults affect future Conversations; existing Pane configuration
and frozen Run snapshots retain their own scope. Show no secret values in lists,
diagnostics or exports. Endpoint/credential conflicts preserve local edits.
Keep the existing explicit Configure callback for an unconfigured empty New;
it enables the approved first-Send path. Formal global default selection uses
its own future-Conversation scope instead of routing every default edit through
that initialization callback. Cover both behaviors independently.

Soul editing advances an immutable version with optimistic revision checking.
Conflicts preserve typed instructions. The approved global disable pauses
injection, keeps versions/bindings and leaves frozen requests unchanged; new
Conversations created while disabled do not automatically bind. Saving text
while disabled must not implicitly enable Soul. Reuse existing Runtime/Soul
scope tests and add actual settings edit-path tests.

Persist appearance in one observable owner, read inside the once-installed
native hosting root. Apply semantic native editor/button colors as well as
SwiftUI appearance; preserve the structural black crop mask and chosen fonts.
New retains its approved configuration entry, routed to the formal Settings
destination; first launch remains New and first Send creates the durable row.

Storage reports actual off-actor database/file bytes and counts. Cleanup only
targets real reconstructible cache; no cache action may clear Session drafts or
Application Support. Unsupported data import/export remains absent. About uses
actual version/build and bundled notices. Resources/Fonts/README.md currently
marks Anthropic Sans distribution rights unverified: a license page cannot
establish missing rights or authorize a font replacement.

Publish actual Sidebar→Settings→Agent→Soul UI RED after the Files full gate,
then test version conflicts, old binding retention, explicit disable and global
default scope. Review and pass the complete macOS source gates before visuals.
Device behavior and distribution acceptance remain separate.

## Additional source preflight

The Blueprint Models page includes capability summaries and model ordering/hiding.
There is no existing catalog-visibility preference owner. Persist real menu
preferences per ProviderInstance/Model identity and consume the same observable
owner in the retained Composer hosting tree. Canonical Provider descriptors and
selected-model capabilities remain intact: hiding a menu choice must not disable
an existing binding or mutate a frozen request. New descriptors keep their
Provider order until the user explicitly reorders them.

Account detail editing reuses reconfigureProviderInstance's expectedEditRevision.
Credential refresh alone has no caller revision parameter, so a reauthentication
flow must not overwrite a different binding merely after a stale row check.
Prefer an owned new credential reference with an atomic revision-checked attach;
failed attachment preserves the previous reference/secret and local endpoint/name
edits, cleans up only the newly owned credential, and reports a safe error.
No secret values enter status labels or diagnostics.


Prepared Startup/New UI draft uses a dedicated empty-store, fake-provider fixture
through the actual AppShellRootView. It requires New Configure -> formal Settings
-> real provider creation/credential save -> the captured original New owner.
Configuring must preserve its draft and leave it uncommitted; actual first Send
removes New Configure and admits Sidebar on the committed Conversation.
The fixture flag ZEN_NEW_CONFIGURE_UI_TEST is not wired yet and this draft is
uncompiled preparation, never an existing-API behavioral RED claim.


Prepared focused-overlay UI coverage goes beyond a Resting-origin draft check:
open Settings from the native Editing owner, edit actual Soul input, then close
without an extra keyboard dismissal/tap. Require Settings/Soul disappearance,
original editor identity/draft/focus and actual keyboard preservation. The native
Search handoff does not itself prove a future SwiftUI Settings editor's lifecycle.
This draft is not compiled evidence. Settings callbacks also capture overlayID.


## Endpoint preflight — explicit security authority

Security note section15 was read directly during Files CI: production defaults
to HTTPS, rejects non-network schemes, and reserves plaintext HTTP for a future
explicit dev/advanced path with disclosure. Formal Settings therefore accepts
HTTPS base URLs only, shows their hostname, and never downgrades after TLS failure.
This is an existing Blueprint requirement, not a guessed transport restriction.
The page does not introduce the future HTTP development exception.

Provider deletion is not necessary for this account-management slice. If added
later, Provider note section6 requires active-Run closure or pending deletion
before destroying credentials/configuration. Current editing and reauthentication
retain old credential references used by frozen requests; no automatic logout of
shared or historical references is part of this slice.


## Concrete ownership before implementation

- AppShell owns one observable persisted appearance/model-menu preference object,
  read inside WorkspaceHostedContent and Composer's installed hosting subtree.
  The global-default callback updates only the future-New target; it does not
  call loadDefaultTarget/installPaneIfReady or rewrite either existing Composer.
- WorkspaceOverlayCoordinator owns each Settings presentation and its captured
  original responder capability. Sidebar admission remains its normal gate.
  The approved New Configure entry gets a separate Settings-only admission that
  validates the captured uncommitted New identity; it does not broaden Sidebar
  eligibility or allow arbitrary overlays from Split/App Space.
- Creating a provider through Settings uses a fresh ProviderSetupModel. A save
  updates global defaults; the optional Configure owner is initialized only if
  the same captured New is still present, uncommitted and unconfigured. Closing
  or moving owners cannot retarget a later Conversation.
- Soul and account edits each own their local draft, expected revision and safe
  error. Native Settings text inputs acknowledge their own responder release
  before the overlay restores the original Composer; teardown cannot clear a
  newly restored responder through scene-wide focus state.
- Storage measurement and presentation-cache cleanup use real detached I/O.
  Cache leases remain in the Files service; neither Settings nor Appearance
  owns Runtime, Session eviction, durable attachments or managed asset lifetime.

## Account actions and native focus transaction

Keep configuration Save and Reauthenticate separate user actions. Configuration
Save reuses reconfigureProviderInstance and updates only the accepted row's
expected edit revision. Reauthentication provisions a fresh owned reference,
then uses existing atomic attachCredential(expectedEditRevision:). A stale attach
preserves the old reference and local input, cleaning only the newly owned
credential; it cannot implicitly save unrelated endpoint/name drafts. Do not add
a combined generic Provider save or change frozen references' generation.

Every editable Settings field registers only its own native responder with the
presentation focus owner. Close requests resignation of that owned responder,
waits for its actual didEndEditing acknowledgement, then closes the matching
overlay and restores its captured Composer capability. Native dismantle only
resigns that old Settings field and cannot affect a restored Composer. Back
navigation detaches that field without closing the overall Settings presentation.
Provider creation's existing native/declarative focus lifecycle needs its own
actual Configure and focused-close UI receipt; Search results cannot prove it.

Storage takes a detached snapshot of the real SQLite path (including WAL/SHM),
unique managed blob bytes, and owned presentation cache. Snapshot rows are counted
and identified as stored within the database; no fabricated separate zero-byte
category. Clear Cache calls only clearPresentationCache and reports retained
leases truthfully. In-memory fixtures report database availability explicitly.

## UI presentation details

The root owns the global Close toolbar throughout Settings subpages. Native
editable fields belong to the Settings focus transaction; the existing Provider
creation sheet must finish its own dismissal before the root can restore the
Conversation. Account status describes local credential configuration and is
explicit about absent network verification. Canonical model capabilities drive
summaries; hidden-menu preferences never rewrite selected capabilities.

One fresh Settings model per overlay loads provider instances, their canonical
model descriptors and the future-New default. Appearance/menu preferences remain
shared and persisted across presentations. An owned default-selection operation
must reject a stale selection generation before publishing; a Configure callback
still checks the captured original New owner. Loading/edit/save failures preserve
local drafts and safe messages; no error string from credential storage reaches
labels. Soul text becomes editable after its initial read and is not overwritten
by a late load or conflicting save.

## New Configure native admission preflight

An empty unconfigured launch already installs a real Pane/Composer; there is no
need to add a placeholder input or remount the pane to configure it. Existing
captureOverlayFocus does not require a durable Conversation, and the native host
can validate marked text, selected text and stable keyboard input separately from
Sidebar's visible-Conversation gate. The new Settings-only request should reuse
that native validation, stable Single/Full scene policy, and captured New ID.
Keep normal Sidebar admission unchanged. Coordinator validates again before
presenting; callback initialization validates original ID and nil configuration
again after the provider save. First Send remains the sole durable-row admission.

## Source ownership map

Keep Settings pages, drafts, storage measurements and native field focus outside
AppShellModel's existing spatial/history implementation. AppShell adds only
services/factory wiring, future-target acceptance and captured-New initialization.
SettingsWorkspaceModel owns catalog/default-selection operations and safe feedback;
ProviderAccountSettingsModel owns one row's edit revision/local form/owned credential;
SoulSettingsModel owns immutable-version editing; SettingsStorageModel owns actual
measurement/cache worker; SettingsInputFocus owns native field acknowledgement.
AppearanceSettings is the shared persisted view preference owner. None retains a
second Runtime, Router or Session owner. Callbacks back into Shell remain weak.

## Owned credential publication preflight

CredentialStore.provision writes generation1 to the secret backend before saving
metadata. A metadata-save failure leaves bytes without a credential record;
logout cannot clean that case because it requires metadata. Formal Settings
reauthentication needs safe ownership of a fresh reference across provision and
revision-checked attachment. Add an existing-API failure regression with the
actual CredentialStore and injected refusing metadata repository, preserving an
independent accepted reference. This untracked draft is not compiled evidence.
Publish it together with existing-API Settings UI RED only after Files FULL.
Any repair remains scoped to fresh provisioning, preserving historical/shared
references and existing rebind semantics; cleanup failures must remain truthful.

The additional existing-API draft simulates metadata committing before its
repository reports failure. A provision compensation must inspect fresh metadata
under the existing per-reference operation lock: a published binding keeps its
secret; an unreadable metadata state is not proof of absence. Only confirmed
unpublished generation1 bytes owned by the fresh provision are eligible for
cleanup. This draft has not compiled and is not a CI receipt. Account attachment
failure remains a separate action over its newly owned reference; existing shared
and frozen references must remain intact.

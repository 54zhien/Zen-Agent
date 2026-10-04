# Stage 5 Global Navigation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete S5-12–15 with the edge-only Sidebar, title Search, real Files Workspace and Settings IA after the Split/orientation code gates.

**Architecture:** Workspace owns one overlay route and preserves the underlying Single Conversation. Separate feature models own bounded Search queries, file operations and Settings edits. Existing Persistence, ManagedFileStore, Runtime and credential boundaries remain authoritative.

**Tech Stack:** Swift 6, SwiftUI/UIKit, GRDB confined to `App/Persistence`, existing `ManagedFileStore`, XcodeGen/macOS CI.

**Spec:** Blueprint navigation note §§13–16, 18; development plan Stage 5 steps 12–15 and open decision 10; data note §§6–7; Prompt/Soul note's version-binding rules; `Design/CONTEXT.md`.

## Global Constraints

- Sidebar “只在已有 Conversation 的 Full Conversation 页面可触发；App Space 和 Split 中不能触发”。
- Sidebar 一级入口只有 Search、Files、Settings。Agent 配置在 Settings → Agent。
- Sidebar 位于 Surface 下层；主 Surface 移动露出它，而不是把 Conversation 内容挤窄。
- Search 只搜索 Conversation Title。Search/Files/Settings 是独立 overlay/fade，进入或退出不 Stop Run。
- FileAsset 是稳定资产身份；Message attachment 固定提交时的 version/content identity。
- Managed FileAsset bytes stay in Application Support, participate in backup, and use their existing explicit file protection.
- Settings uses grouped/inset grouped presentation. Unsupported later-stage capabilities do not get working-looking empty controls.
- No merge or device-acceptance claim. Each slice passes full macOS XcodeGen/build/unit/UI CI before the next slice begins.

## Review Focus

1. A selected/pending-deleted Conversation never reappears through Search or a stale completion.
2. Closing an overlay restores the same draft, reading state, Session and active Run.
3. Import cancellation or I/O/database failure cannot leave partial assets or UI-thread file reads.
4. File removal cannot damage historical attachments, active request versions or unsent draft references.
5. Settings changes apply to the correct scope: global defaults affect new Conversations; existing Soul bindings and running request snapshots do not change.

## Task 1: S5-12 Sidebar admission and retained Surface

**Files:**
- Create `App/Workspace/WorkspaceNavigationState.swift` and `App/Workspace/SidebarRailView.swift`.
- Modify `App/Workspace/WorkspaceSurfaceView.swift` and its native Surface host/gesture boundary.
- Tests: `Tests/ZenAgentTests/WorkspaceNavigationStateTests.swift`, `Tests/ZenAgentUITests/SidebarUITests.swift`.

**Interfaces:**
- `WorkspaceOverlayRoute` has `.search`, `.files`, `.settings`.
- `WorkspaceNavigationState` owns rail progress and optional overlay route; `openSidebar(eligible: Bool) -> Bool`, `closeSidebar()`, `present(_ route: WorkspaceOverlayRoute)`, `dismissOverlay()`.
- Eligibility consumes the actual Full/Single Surface state, existing Conversation owner, text selection, composition and overlay state. It does not infer availability from a remembered stage number.

- [ ] Add compiled UI RED: a leading-edge swipe reveals Search/Files and bottom Settings while preserving the content width; normal interior swipe and Split/Card states cannot reveal it. No toolbar Sidebar button exists.
- [ ] Implement a native leading-edge recognizer with arbitration against system navigation, text selection, Browse and Lift. Start near 60 pt Rail width and clamp to real safe geometry. Tap the shifted Surface or reverse swipe closes it.
- [ ] Expose an equivalent “打开侧边栏” accessibility action on the stable Full Surface; cancel interrupted edge drags to the last stable state.
- [ ] Establish the typed overlay route consumed by the following tasks. A destination is selectable only once its real feature handler exists; do not route to an empty or no-op page during intermediate draft work.
- [ ] Verify rapid edge reversal, background interruption, Full-to-Card arbitration and retained draft/reading/Run ownership. Pass full CI, review, and record exact evidence.

## Task 2: S5-13 title Search

**Files:**
- Create `App/Persistence/PersistenceStore+ConversationSearch.swift`, `App/Search/ConversationSearchModel.swift`, `App/Search/ConversationSearchView.swift`.
- Modify Workspace overlay composition and Single's temporary Recent entry.
- Tests: `Tests/ZenAgentTests/ConversationSearchTests.swift`, `Tests/ZenAgentUITests/ConversationSearchUITests.swift`.

**Interfaces:**
- `PersistenceStore.searchConversationSummaries(query: String, limit: Int, after: ConversationSummaryCursor?) throws -> ConversationSummaryPage` returns visible display-title matches in the existing stable keyset order. Match the same first-user-prompt fallback as the summary projection when an explicit title is empty, so an unnamed used Conversation remains searchable.
- `ConversationSearchModel` owns query text, bounded rows, cursor, query generation and retry feedback. Database work runs away from the presentation actor; stale queries cannot publish.
- Result activation calls the existing asynchronous `AppShellModel.openConversation(id:)`; only successful activation closes Search.

- [ ] Add compiled UI RED for Sidebar Search: keyboard appears, input/exit control sits above it, results show a thumbnail/title row, a tap opens the target, and exit without selection restores the original draft.
- [ ] Add persistence regressions for Chinese and ASCII titles, literal `%`, `_` and backslash, empty/whitespace query, pending/finalized deletion, stable paging, and query replacement during a slow read.
- [ ] Keep fallback matching bounded to the actual provisional title. Existing summary projection normalizes Unicode whitespace and clips to 56 characters after a bounded first-prompt read; searching the entire first Message would silently become body search. Reuse a shared title derivation so returned title, keyword matching and highlight agree. Cover a keyword beyond the derived title, malformed/whitespace-only first parts, and a manual title overriding the fallback.
- Search SQL preflight: the repository pins GRDB 7.11.1. Keep Unicode display-title derivation and literal match semantics shared between SQL filtering and row projection. GRDB supports a pure DatabaseFunction registered on the read connection; use parameterized query input and bounded 512-character first-prompt input before the 56-character display-title clip. Return only a bounded keyset page, never all Conversation rows to a Swift filter. A full title scan remains possible without a search index; this does not authorize a schema/index migration or full-body matching. Verify the pinned API before implementation.

- [ ] Implement bounded parameterized title matching, lightweight thumbnail/title rows with match highlighting, debounce/cancellation, loading/error/retry and load-more. Do not instantiate live history Panes for result thumbnails.
- [ ] Connect successful result activation to the existing Pane replacement transaction. Keep an active outgoing Run alive; failed/stale loads keep Search and the original owner intact.
- [ ] Remove the explicitly temporary Single Recent entry only from a live Full Pane once Search is reachable. Retain Recent on the no-Pane New Conversation screen and per-Pane Recent in Split. Test no-Pane → Recent → existing Conversation → Sidebar/Search.
- [ ] Pass full CI and review, including simultaneous streaming plus Search open/close/selection and native keyboard placement.

## Task 3: S5-14 Files Workspace

**Files:**
- Extend `App/Persistence/PersistenceStore+FileAssets.swift` with bounded listing/reference checks and atomic unreferenced deletion.
- Reuse `App/Files/ManagedFileStore.swift`; extend it only where verified removal/export semantics require it.
- Create `App/Files/FilesWorkspaceModel.swift`, `App/Files/FilesWorkspaceView.swift` and a small native preview adapter if needed.
- Tests: `Tests/ZenAgentTests/FilesWorkspaceTests.swift`, existing ManagedFileStore/attachment/deletion tests, `Tests/ZenAgentUITests/FilesWorkspaceUITests.swift`.

**Interfaces:**
- `FileWorkspaceItem` projects asset ID, current version ID, display name, media type, byte count and availability; it contains no binary payload.
- `FilesWorkspaceModel.importFile(at: URL) async` consumes system-picker URLs, scopes access for the entire copy and calls `ManagedFileStore.ingest(fileAt:displayName:mediaType:in:)` off the UI actor.
- `FilesWorkspaceModel.removeAsset(id: String) async` asks the AppShell/Session owner for a removal lease covering attachments in every retained Session (both Panes, warm drafts and send snapshots awaiting acceptance). Serialize acquisition/removal against attach/send acceptance; the Files view must not independently inspect only the current Composer. Durable Message references protect accepted submissions. Referenced assets stay intact and return a readable reason.
- Under the existing managed-file operation lock, atomically remove unreferenced metadata in the database, then clean up only blobs no longer referenced. A crash or cleanup failure may leave recoverable orphan bytes; database and filesystem do not share a transaction, and referenced bytes must never be removed first.
- Preview/export use a verified immutable version URL, never a stale external bookmark or a rewritten history attachment.

- Ownership preflight: production `ConversationPaneView` injects the coordinator already retained by `ConversationSession.sendCoordinator`; the Composer view keeps that same instance in `@State`. Its pending attachment snapshot is private, and the Composer's weak coordinator pointer exists only under DEBUG. Reuse the existing Session owner: expose a read-only pending-reference query on the coordinator, combine it with draft references in the Session, and enumerate all retained Sessions at the store boundary. Do not introduce a second submission owner or use the DEBUG pointer. Cover changing a draft after `beginSend`, navigating it warm, and attempting removal before acceptance; acceptance/rejection remains the only matching-snapshot release authority.

- [ ] Add compiled UI RED for a real Files overlay reached from Sidebar, a Files list and an import entry; closing returns to the same Conversation and draft.
- [ ] Add service tests using temporary directories: import bytes, list the created version, verify digest, cancel mid-copy, force database failure, preserve duplicate-content blobs, reject unsafe paths, and report missing/corrupt bytes without deleting metadata.
- [ ] Implement a single-level Workspace and system Document Picker only for import/export. Preserve existing backup/protection rules and stable IDs; don't copy binary data into Message text.
- [ ] Add immutable preview/export and guarded cleanup. Test a file shared by two Messages/Conversations, an old referenced version after currentVersion advances, a secondary Pane draft, a warm draft and a send awaiting acceptance; all referenced bytes survive removal attempts and Conversation deletion. Exercise real preview/export controls, picker cancellation and exported-byte identity.
- [ ] Keep Workspace presence separate from Agent read permission. Existing Composer attachment/capability gates change only when the complete native selection→version reference→send path is wired and proven; a Files list alone cannot enable attachment Send.
- [ ] Pass full CI and review filesystem/database cancellation, reference retention and overlay restoration. Do not add Stage 6 Files Tool policy here.

## Task 4: S5-15 Settings IA and real configuration

**Files:**
- Create `App/Settings/SettingsView.swift`, `App/Settings/AppearanceSettings.swift`, `App/Settings/SoulSettingsModel.swift`, `App/Settings/SoulSettingsView.swift` and focused model/storage/about pages as their real behavior is added.
- Reuse `App/AppShell/ProviderSetupView.swift` and its model, `App/Persistence/PersistenceStore+Soul.swift`, existing model/credential stores and resource licenses.
- Modify Workspace overlay composition and application appearance injection.
- Tests: `Tests/ZenAgentTests/SettingsScopeTests.swift`, existing Soul persistence/binding tests, `Tests/ZenAgentUITests/SettingsUITests.swift`.

**Interfaces:**
- `AppearanceSettings` persists `.system`, `.light`, `.dark` and supplies the preferred color scheme to the root. Visual-effect controls arrive with their working renderer in S5-16.
- `SoulSettingsModel` loads the current version, keeps an editable local draft, and saves with `advanceSoul(expectedCurrentVersionID:to:at:)`; first explicit save creates Soul. Conflict/failure preserves typed content.
- Global model-default editing persists the default target without rebinding an existing Conversation or Run. Conversation-level model selection remains in its Composer.
- Provider management lists existing instances, opens details, edits endpoints with revision checks and reauthenticates through the credential store. The existing setup screen is a creation/credential subflow, not the whole account-management page. Models exposes per-instance available models and the real default-selection path.

- [ ] Add compiled UI RED for Sidebar→Settings and close restoration, grouped navigation, and Settings→Agent→Soul. No standalone Sidebar Agent entry is introduced.
- [ ] Build groups: 模型与服务, 外观, Agent, 文件与存储, 数据与隐私, 关于. Wire Providers & Accounts / Models to real stores, Appearance to root appearance, Soul to versioned persistence, Files to the real Workspace, and Storage/About/privacy to truthful current data and bundled licenses.
- [ ] Show only supported Agent configuration: Soul is live; Memory/Skills/MCP/tools/subagents/environment editing follows their Runtime stages. Do not introduce empty switches or imply that placeholder settings affect requests.
- [ ] Verify saving a new global model default leaves both existing Pane configurations unchanged and changes only future Conversations. Verify Soul edits preserve old Conversation binding and frozen Run snapshots, including edit conflicts. Implement and test global Soul enablement from the explicitly verified Prompt/Soul Blueprint: disabling pauses effective injection, keeps versions and existing bindings, and creates no automatic binding for Conversations created while disabled. Existing frozen Run snapshots remain unchanged.
- [ ] Storage cleanup may remove only reconstructible cache/derived files. Conversation/managed-asset deletion is a separate explicit destructive flow; do not implement “clear cache” by clearing Session drafts or Application Support.
- [ ] Verify secret values never enter settings summaries, diagnostics or exports. About shows actual version/build and licenses; unsupported export/import capabilities stay absent.
- [ ] Pass full CI and review all overlay restoration, scope and credential boundaries before S5-16.

## Decisions awaiting the owner

The earlier optional Soul-scope question is resolved for implementation by the explicit current Blueprint baseline, not by inference from SQL: global disable pauses injection while preserving bindings and snapshots. Marked-text navigation/focus and light-mode Ink remain optional owner preferences. Do not silently commit/cancel composition, invent a Sidebar workaround or treat the existing global Soul storage toggle as approval for global product semantics. Work independent of those decisions continues in order.

## Preflight rulings — 2026-10-04

Ruling: follow the existing explicit global Soul enablement baseline while the
owner has not requested a replacement policy. The current Prompt/Soul note
labels version semantics as product invariants and explicitly says global
disable pauses injection, keeps versions/bindings and does not bind Conversations
created while disabled. Frozen Run snapshots retain their own authority.
The earlier question arose from confusing version immutability with enablement
scope; SQL alone did not settle it. Cost if the owner chooses future-only later:
change the enablement policy and its scope tests, preserving historical records.

GRDB DatabaseFunction API was checked at the repository's exact v7.11.1 tag:
https://github.com/groue/GRDB.swift/blob/v7.11.1/GRDB/Core/DatabaseFunction.swift
Read-connection registration is explicitly shown by upstream; no database-schema
mutation is needed for a shared pure display-title/match function.

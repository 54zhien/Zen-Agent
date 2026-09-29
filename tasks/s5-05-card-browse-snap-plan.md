# S5-05 Card Browse / Snap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. One independent whole-branch review at the end; no implementation agents.

**Goal:** Browse real Conversation summaries in the existing right-biased depth stack, snap at most one neighbor per gesture, and explicitly open the selected Conversation through the same Surface.

**Architecture:** Workspace owns bounded browse selection and pure motion state. Persistence supplies summary neighborhoods through the existing bounded SQL projection; Runtime/Session/Pane ownership stays unchanged. The native Surface host transports horizontal input and existing animation style; Full preparation happens only on explicit activation.

**Tech Stack:** Swift 6 strict concurrency, iOS26, existing UIKit/SwiftUI host, GRDB7.11.1, XcodeGen/macOS CI.

**Spec:** User's pasted S5-05 plan at `C:/Users/Azusa/.codex/attachments/2d1211e4-9ea0-4de6-82d8-69bfc1d66023/已粘贴的文本.txt`; Blueprint596a84d `Design/Zen Agent 开发规划.md`, `Design/CONTEXT.md`, `Design/Zen Agent App Space、Split 与全局导航.md`.

## Global Constraints

- Base H2 squash `eec3eb38c3d4869a58031449f303f04dec55d0fd`, tree `2d8f16749fb0cdfcf328982d73250d073e612777`; main integration CI must pass before published feature RED/source.
- Owner now authorizes H2 merge → S5-05 development while physical Gate A stays OPEN. No device/performance/comfort acceptance inferred from CI.
- Keep Current + up to3 predecessors +1 real successor summaries. No full-history/all-page preload, second database, Run owner, native editor or Session during browse.
- Reuse native Surface host; no second SwiftUI DragGesture or unrelated UIKit transition. Full gestures remain with ComposerLiftInteraction.
- No New creation, Pin, Rename, Delete/Undo, Split, Sidebar, Search, Files, Settings, schema, dependency, signing or IPA work.
- Example names and numeric thresholds are implementation suggestions. Snap uses normalized card travel and velocity projection, clamps to one available neighbor, validates finite inputs.
- Old source Downloads report is currently absent; saved repair ledger/task records remain available. Do not infer missing later-stage requirements.

## Review Focus

1. Failed summary neighborhood/Full reads must retain readable selection and original Session; stale completions cannot commit a different target.
2. Repeated/far browsing cannot accumulate summaries, Panels or Sessions; 100-history fixture must exercise distant windows.
3. Drag cancellation, viewport/scene changes and Return during settlement restore a committed selection without late animation completion changing it.
4. Live projection refresh cannot reorder the in-flight drag or change userActiveAt; missing/unavailable rows remain explicit.
5. Uncommitted current page and real-history edges must not create a new Conversation through the New sentinel; accessibility navigation has equivalent one-step behavior.

## Task 1 — Runnable native behavior RED

**Files:** new `Tests/ZenAgentUITests/AppSpaceBrowseUITests.swift`; existing Preview fixture only.
**Interfaces:** consumes existing `ZEN_PREVIEW_HANDOFF_UI_TEST`, `workspace-current-card`, real `preview-ui-11` and12 persisted summaries. Produces compiled gesture/selected-return failure evidence without new product APIs.

- [x] Lift existing fixture, prove Card/no editor, swipe right toward older neighbor, assert Card stays present and title changes11→10.
- [x] Swipe left10→11, then one fast right swipe11→10; no multi-card jump. Activate selected Card and assert Full target10 with exactly one editor.
- [x] Publish tests only and observe real native behavior failure after test compilation; compiler/fixture errors do not count RED.

## Task 2 — Bounded selection, motion and summary source

**Files:** `App/Workspace/AppSpaceBrowseState.swift`, `AppSpaceBrowseController.swift`, `AppSpaceBrowseGeometry.swift`; extend `PersistenceStore+ConversationSummaries.swift`; tests `AppSpaceBrowseTests.swift`, existing `ConversationSummaryTests.swift`.
**Interfaces:** state consumes existing `AppSpaceGeometry.Item`; motion accepts finite displacement/velocity/card travel, produces previous/current/next one-step settlement with UUID. Controller receives a throwing summary-reader closure and holds only summaries/selection. Reader uses current ID lookup and bounded keyset older/newer queries, sharing existing summary projection SQL.

- [ ] After native RED, introduce runnable inert pure APIs as a recorded scaffolding exception where new API tests cannot exist on the base. Never claim missing symbols as RED.
- [ ] Unit cases: tiny/large drag, opposite release velocity, both boundaries, cancellation, interrupted/obsolete settlement, invalid/zero width, single-card velocity cap.
- [ ] Read actual100 records with pinned/date/ID ties; nearest newer and older rows, stable cursors, localized unavailable row, global failure preserves current window, retained summary count≤5.
- [ ] No copied Card projection type if ConversationSummary already supplies title/excerpt/status. Use existing ConversationPreviewView and ConversationCardStatus derivation.
- [ ] Native RED and new pure tests drive minimal implementation. Freeze ordered IDs for each drag; successful settlement re-centers/reloads a bounded neighborhood.

## Task 3 — Native interaction, depth interpolation and explicit Full activation

**Files:** `ConversationSurfaceHost.swift`, `SurfaceLiftController.swift`, `WorkspaceSurfaceView.swift`, `NewConversationView.swift`; minimal target-aware changes `AppShellModel.swift`, `ConversationPreviewController.swift`; native/unit/UI tests.
**Interfaces:** native host has one card-only horizontal recognizer, window coordinates, cancellation and animation completion token. Workspace renders selected summary into the existing Surface and background depth cards. SurfaceLift preparation closure passes the selected ID only on activation; its animation/handoff remains the existing two segments.

- [ ] Horizontal direction lock; vertical input does not browse. Full/settling/overlay/prepare cannot begin a new browse; no drag-release activation masquerading as a tap.
- [ ] Interpolate the whole depth stack using existing AppSpaceGeometry; preserve right bias, scale/depth and finite geometry. No hundred Card views; at most5 bounded projections.
- [ ] Native host settlement uses existing animation style and Reduce Motion; cancellation/viewport/scene changes invalidate completion generations.
- [ ] Expose native “上一会话”/“下一会话” actions on Current, boundary-aware. Test actual native actions directly in hosted unit tests (no fake SwiftUI API).
- [ ] Extend existing preparation to accept a selected target while retaining original Session until commit. No Full read or Session construction during browse. Correct cancellation routes to the actual target.
- [ ] Cross-ID commit must retain continuous Surface animation, original draft/reading warm state and hidden Run; returning to original uses same Session. Failed Full open leaves selected Card and original owner retryable.
- [ ] New sentinel stays non-creating; an already uncommitted original page can return to its retained warm owner. No new page creation action.
- [ ] Existing native UI RED passes unchanged; add ownership/no-userActiveAt/no-Stop/100-window controls and cancellation/failure tests. UI tests exercise multi-window traversal, short/fast drag and selected Return.

## Task 4 — Actual full CI, independent review and receipt

- [ ] Static path/whitespace/hygiene checks, exact staged-tree publication; no generated project changes.
- [ ] Exact-source XcodeGen/build/full unit/UI CI, actual counts and host restart guard. Preserve earlier input failures and new failures; no weakening assertions.
- [ ] One fresh read-only whole-branch reviewer against base eec3eb3; re-grade every finding and every declined behavior. One Important/Critical test-first fix pass; minor findings ledgered.
- [ ] Record source/tree, PR, pushed/unmerged state, relevant RED/GREEN and gate status in receipt/README. Physical Memory Graph, SwiftUI body count, animation hitches, peak memory and comfort remain unmeasured until actual device traces.

## Implementation rulings

- Existing code has no SurfaceGesture API. Reuse SurfaceClipView/SurfaceLift host and install one native card-only horizontal recognizer; Composer long press remains the Full input owner. Cost if wrong: native gesture arbitration adjustment.
- Current browse identity differs from the original Full Session identity. Selection commits only the projection; explicit activation uses the existing history owner. Cost if wrong: handoff/cancellation could replace the wrong Session, covered by targeted tests.
- Preserve existing canonical pinned/userActiveAt/id ordering and left-stack geometry. Older is the existing `after` cursor direction; nearest newer uses its inverse keyset, not an all-row scan. Cost if wrong: neighboring-card direction needs correction against canonical tests.

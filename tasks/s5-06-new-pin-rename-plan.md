# S5-06 New / Pin / Rename Implementation Plan

> Use superpowers:executing-plans inline; one fresh whole-branch review at completion.

**Goal:** App Space creates a durable empty Conversation through its rightmost New entry and edits only selected-card metadata.
**Spec:** Blueprint 596a84d, App Space note sections 5/6/19; message/data note Conversation Title and userActiveAt; CONTEXT. User requires strict Stage5 order and defers all device acceptance until Stage5 development ends.
**Base:** bca95d9bd1e083be1f9e1c21ab6a0dc1f85f64c6 (PR22, tested, unmerged). PR targets codex/s5-card-browse-snap until that dependency integrates.
**Architecture:** bounded Browse owns selection; persistence owns metadata and durable creation; existing Preview/HistoryPreparation/Session/Lift owns explicit Full activation. Workspace owns only current-card menu presentation.

## Global Constraints

- New stays rightmost; plus and 新对话; no ellipsis/Run state/delete. Explicit click creates a normal durable history item, then existing Surface returns to its empty Full with Resting Composer and no keyboard.
- Keep original draft/read owner/hidden Run during selected/New preparation and cancellation; never send Stop for navigation.
- Pin uses existing pinned dimension; Pin/Rename/open/browse never change userActiveAt. Freeze IDs during motion, refresh bounded window after metadata success.
- Rename persists a manual-title marker; later Send cannot overwrite it. No automatic model-title request.
- Current +3 older +1 newer only; no Full history or Session while browsing or editing metadata. Pure New is a distinct entry from an uncommitted warm original.
- No Delete/Undo/Split/Sidebar/Search/Files/Settings/shader/IPA/signing/dependency work. One additive migration only if required for persistent manual naming; preserve old migration test schemas.
- Existing no-target/default binding and immutable Soul version rules also apply to explicitly created empty histories.
- Windows has no Swift toolchain; publish exact staged tree, use real macOS generation/build/full tests; compile failure is never RED.

## Review Focus

1. Menu opened on A then selection/scene changes must not edit B; cancelled Rename changes nothing.
2. New failed creation/Full preparation and repeated taps must preserve readable card/original owner and avoid duplicate creation.
3. Pin reorders pinned group while selection stays on same ID, never invalidating in-flight geometry or activity dates.
4. Empty durable histories must open/reopen/Send with configured and unconfigured targets, preserving immutable Soul binding and manual title.
5. Real native accessibility must distinguish New activation from original warm Return and expose selected menu actions without requiring visual gestures.

## Task 1 — Existing native-path RED

Files: Tests/ZenAgentUITests/AppSpaceMetadataUITests.swift.
- [ ] Existing fixture Lift 11, swipe toward rightmost New, assert 新对话 instead of returning original; activate into empty Full with one editor, no keyboard, re-Lift sees history plus New.
- [ ] Existing selected Card ellipsis presents Rename and Pin only; rename real TextField; Cancel unchanged, Save updated; Pin/Unpin remains selected.
- [ ] Tests-only publication, compiled actual behavior failure, old unit/UI controls intact. Expected: missing New/menu behavior, not symbols/fixture failure.

## Task 2 — Durable metadata and bounded New selection

Files: new PersistenceStore+ConversationMetadata.swift, Migrations.swift; Browse controller; AppShellModel minimal wiring; unit tests.
- [ ] After native RED, runnable inert new methods only where old API cannot express unit assertions; ledger this compatibility scaffolding, require actual behavior RED before implementation.
- [ ] Persistence tests: visible-only rename/pin, Unicode/whitespace validation, failed write rollback, metadata timestamp monotonicity, activity unchanged, manual marker durable/reopen, stale Send preserves metadata, empty creation exactly one/Soul binding.
- [ ] Browse tests: actual New after newest persisted row, distinct warm origin, >100 history bounded windows, cancellation/stale completion, New reader failure keeps selection, selected Pin reload preserves ID.
- [ ] Implement metadata transactions with no whole-record stale overwrite; one additive manual-title marker table avoids changing Codable records used against old schemas.
- [ ] New preparation creates exactly one ID, reuses existing selected history preparation, retains original owner until commit, marks failed target retryable. Selected Rename/Pin do not construct Session.
- [ ] Full unit controls cover old Run no Stop, selected New retry/cancel, empty history first Send/manual title/Soul binding; require actual full GREEN.

## Task 3 — Current menu and New native activation

Files: new AppSpaceCardActionsView.swift; WorkspaceSurfaceView/NewConversationView; minimal native host accessibility actions.
- [ ] Real ellipsis outside frozen editor subtree aligned to actual Current frame. Menu/rename freezes selection; action snapshot captures ID; failure keeps readable Card and retry message.
- [ ] New renders plus/新对话; native activation dispatches one create/preparation through existing two-segment Return. No auto keyboard.
- [ ] Native accessibility Current actions include selected metadata equivalents; New has create/navigation only, no metadata/Run state. Scene or interrupted Return invalidates obsolete work.
- [ ] Original RED UI assertions pass unchanged, selected metadata/New failure/cancel/native controls pass; full actual CI.

## Task 4 — Review and delivery

- [ ] One fresh readonly reviewer whole bca95d9..HEAD, spec/Review Focus/ledger supplied. Lead regrades findings and declines; at most one Important/Critical RED→GREEN repair pass.
- [ ] Static default diff checks, exact source/merge trees, actual full generation/build/test counts and restart guard; README/receipt retains all failed evidence.
- [ ] Final exact-head CI, ready unmerged PR, device acceptance deferred to Stage5 end. Stop before S5-07.

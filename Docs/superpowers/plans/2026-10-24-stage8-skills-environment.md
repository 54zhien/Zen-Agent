# Stage 8 Skills and Environment implementation plan

> **For agentic workers:** Use superpowers:executing-plans inline with superpowers:test-driven-development. The owner approved the full stage, UI additions, next-request manual activation and Global -> active-Skill precedence. Execute all tasks without repeated permission checks. Delegate read-only investigations and one whole-branch review.

**Goal:** Complete versioned Environment configuration and usable built-in/user-created Skills, deterministic manual activation and bounded routing without widening Tool authority or exposing secrets.
**Architecture:** PersistenceStore owns immutable revisions and atomic Send associations; EnvironmentRuntime/SkillRuntime own validation and selection. ConversationRuntime freezes actual references; AgentRuntime/RunRecovery reuse and validate them under the existing per-database handoff gate. Settings/Composer consume the same services and preserve draft ownership.
**Tech Stack:** Swift 6, iOS 26, SwiftUI/UIKit, GRDB, existing CredentialStore/Keychain, XcodeGen/macOS CI.
**Spec:** [Approved design](../specs/2026-10-24-stage8-skills-environment-design.md).
**Base:** Stage 7 f335204b387e9a5ca10fa2091dbb24e4e3368296; branch codex/stage8-skills-environment-20261024. Main and other worktrees are untouched.

## Global constraints

- Global base then only the active Skill's overrides; only declared keys participate.
- Composer selection belongs to its Conversation draft and is consumed only after successful Send commit; subsequent steps/recovery use the original durable selection.
- SecretValue never becomes a Codable config, Prompt, Memory, diagnostic or ordinary Tool Result. Fresh opaque references preserve ordinary secret revisions; explicit erasure/revocation wins.
- Skill instructions do not grant permission or add tools. Required tool existence is separate from Tool Policy and approval.
- UI changes are limited to the approved Settings/Composer capability additions. Preserve existing geometry, text arrangement, animation, gestures and input owner.
- No MCP/Subagent runtime, marketplace, model router, extra model call, merge or IPA delivery.
- Full normal source CI stays unchanged. Preserve native RED, compile failures and failed full gates separately; physical acceptance remains separate.

## Review focus

- Two editors save concurrently or secret provisioning succeeds but metadata/CAS fails: preserve the committed version and clean up only newly owned bytes.
- A delete/disable races a queued provider request or displayed Tool approval: future dispatch fails closed and the original Run settles without replay.
- A committed Send fails preparation or its response is lost: original selection is durable and duplicate submission cannot change its payload.
- Environment overrides, unknown/cyclic references and instruction text containing secret-like values: no sibling-scope or secret escape into context/Memory/results.
- Cold recovery of deleted Skill/env dependencies with existing file-operation proof: release original active slot and confirm proof without repeating writes.

## Task 1: Global Environment store and credential boundary

**Files:** Create App/Environment/EnvironmentTypes.swift, EnvironmentRuntime.swift; App/Persistence/Migrations+Extensions.swift, EnvironmentRecord.swift, PersistenceStore+Environment.swift. Modify Migrations.swift and trusted known-secret validation helpers. Tests EnvironmentPersistenceTests.swift, EnvironmentRuntimeTests.swift.
**Interfaces:** EnvironmentScope.global / .skill(id), EnvironmentRevisionReference(variableID,revisionID), EnvironmentItem(id,revisionID,key,scope,value), EnvironmentStoredValue.plain(String)/.secret(CredentialBindingSnapshot). Store list/save CAS/resolve exact versions/delete and enumerate owned references. Runtime savePlain/saveSecret validates content; secret provisioning precedes reference commit, failed commit retires only fresh reference; freeze/resolve rejects erased dependencies.

- [x] Native RED: real v21 disk upgrade preserves data but lacks Environment schema; immutable versions and XOR plain/reference constraints.
- [x] Implement v22 schema and Global domain/store with same-scope uniqueness, bounded inputs and immutable revisions.
- [x] RED then GREEN for CAS, key validation, plain-value safety, secret write-before-attach, failed-write cleanup, frozen old secret identity, binding revocation and disk reopen.
- [x] Audit Memory/Skill/plain/result secret exclusion at trusted boundary; never expose broad CredentialStore to Skill content.
- [x] Run all native units, record source/diagnostic distinction and commit evidence. Expected: App build + all existing units and Environment tests pass.

## Task 2: Skill catalog, manual activation and approved management UI

**Files:** Create App/Skills/SkillTypes.swift, SkillCatalog.swift, SkillRuntime.swift; App/Persistence/SkillRecord.swift, PersistenceStore+Skills.swift; App/Settings/SkillSettingsModel.swift, SkillSettingsView.swift, EnvironmentSettingsModel.swift, EnvironmentSettingsView.swift. Modify Migrations+Extensions.swift (new migration), SettingsWorkspaceModel/View and privacy view, SendCommand, SendCommit/persistence, Composer draft/Pane/Host interfaces, ConversationRuntime, PromptComposer, RunExecutionSnapshot and RunRequestRebuilder.
**Interfaces:** SkillDefinition has stable ID/source, immutable revision, instructions and declared required/optional tools, MCP IDs, env keys and router terms. SkillRuntime.seedCatalog/list/copy/save/setEnabled/prepare/resolveFrozen uses registry and EnvironmentRuntime. SkillActivationReference(skillID,revisionID,environment bindings) carries no text or secret; frozen references associate with original Run. SendCommand.selectedSkillIDs defaults empty for compatibility and is part of submission digest. Durable Send association is atomic; UI clears only its original draft generation after commit.

- [x] RED: actual built-in enable/copy/immutable edit, manual-selected-only provider request, legacy snapshot compatibility and stale/missing dependency refusal.
- [x] Implement two modest built-in workflows using existing Calculator and Files tool IDs. No new executor or authority.
- [x] RED: duplicate submission with changed Skill selection, failed Send retains draft selection and exact original Conversation ownership.
- [x] Implement next-request manual selection through existing plugin entry and durable Send boundary. Selected instructions remain untrusted user/workflow context with explicit current-request priority.
- [x] Implement approved native Forms, explicit saves, dependency summaries and confirmed deletion. Secrets stay masked with no reveal path. Use existing focus/close owner and safe typed errors.
- [x] Native units + focused management/activation UI GREEN; inspect native captures including dark/largest-type inputs. Expected: no draft/selection transfer or unrelated UI modification.

## Task 3: Dependency-aware router and scoped Environment

**Files:** Create App/Skills/SkillRouter.swift; extend EnvironmentRuntime/SkillRuntime, store dependency queries and approved scope editors. Tests SkillRoutingTests.swift, SkillEnvironmentTests.swift, SkillPromptIntegrationTests.swift.
**Interfaces:** SkillRouter.select(query:definitions:) returns a deterministic bounded subset. Explicit selection is authoritative and failure is visible; automatic routing skips unavailable definitions. Per-Skill environment freezes only declared key references, with Skill overriding Global. Plain interpolation uses pinned revisions; secret interpolation is refused. Resolver accepts trusted frozen binding and declared key, never arbitrary model-provided credential reference.

- [x] RED: enabled is not injected wholesale, unrelated input selects none, local bilingual positive routes, deterministic limit/order and manual precedence.
- [x] Implement simple local routing and real dependency status, distinguishing present/ask/denied/missing and unsupported MCP prerequisites.
- [x] RED: Global/Skill override, sibling isolation, missing variables, malformed/cyclic references, secret Prompt refusal and immutable recovery after edits.
- [x] Implement scoped references and revision/fingerprint validation; actual Secret bytes resolve only at trusted executor seam tests, with no shipped fake secret consumer.
- [x] Native all-unit + focused new UI GREEN. Expected: required dependencies cannot grant Tool permissions or expand exposure.

## Task 4: Erasure, recovery, review and complete source gate

**Files:** Extend existing AgentRuntime/ToolRuntime/RunRecovery/RunRequestRebuilder and dependency erasure services, snapshot codecs; add SkillErasureTests.swift and native SkillsSettingsUITests.swift/EnvironmentSettingsUITests.swift. Add tasks/stage8-skills-environment.md and README receipt; update Blueprint decisions on a draft branch/PR.

- [x] Native RED: queued Stop/delete, displayed approval revocation, user-created Skill erasure, environment binding revocation, cold-original-owner settlement and existing file-write proof preservation.
- [x] Implement minimal checks under the existing per-database handoff gate. Dependency destruction settles/stops original execution before removal; no hidden body copy, stale dispatch or replay.
- [x] Run one independent whole-branch review against base f335204; reproduce and fix material findings in one corrective pass with native RED -> GREEN and green suite. Record all rulings/deferred minors.
- [x] Inspect actual dark/light/largest-type portrait/landscape screenshots and interaction. Preserve existing resize-dismiss policy and exact Form-visible navigation harness.
- [x] Push final source and run unchanged normal ci.yml Phone/Pad gate. GREEN on exact source `def1fcd27f61e38acac02fa51c274664077b252b` in run `40049658208`; details and remaining receipt work are recorded below.
- [x] Create/attach draft implementation PR stacked on Stage 7 and draft Blueprint decision PR, preserve failure receipts, record exact source/tree/jobs and tested input equivalence. Keep both unmerged; physical acceptance open.

### Retained close-top keyboard-anchor follow-up (focused GREEN; three full REDs retained; native implementation gate GREEN)

The original full Phone/Pad gate remains failed at the surviving-editor text
assertion. Focused trace `40022375226` established a real geometry defect:
eight top samples had keyboard visible and editor focused, but the retained
portal's local guide was `(0, 778, 0, 0)` while the root keyboard guide was
`(0, 539, 402, 335)`; the active converted frame was `(0, 477, 402, 335)`,
the measured gap was `-289` against 12-point spacing, and the saved capture
shows the keyboard covering the Composer.

Source `6767b64992f06b0efb25724b2412099f321a8a3b` preserves the local constraint
and existing editor, adding an invalidatable root-guide geometry observer that
invalidates Composer geometry caches and requests ordinary host layout. Focus,
animation, and motion behavior stay unchanged. The same bounded source reviewer
approved the Host/Observer lifecycle and accessibility boundary.

Focused run `40028246136` (diagnostic `48f1fecc95ed5f151426ac260721d21f19d72f0b`,
job `120669792003`) passed 28 Swift tests in 3 suites (30.075 seconds) and all
3 selected UI cases (89.654 seconds), with no skips, failures, or host restarts.
The UI cases were drag-close with a focused secondary editor (50.136 seconds),
close-top retaining the secondary editor (39.420 seconds), and the current
Composer receipt parser control (0.098 seconds). Its 805,210-byte log SHA256 is
`f35a631ccf06f41f8164b2b2986371a24718123f511eb644cf67bf80abb37173`.
Artifact `12533909454` (101,010,111 bytes) was fully downloaded and matched
GitHub SHA256 `b7dc8283f2789913ff5c248cfd2c195b3c8cb37584fd5cd87187ab78fef2a67a`.
Although that workflow contained a nonexistent Bottom/Primary selector, the
selected top/drag/parser cases passed; supplemental run `40028277525` selected
the actual `testExplicitCloseBottomKeepsTheSourceConversationEditable` control
and passed in 49.958 seconds. Its log SHA256 is
`00e4e40357a187f3503bdf1ba5af200ee58a0462d498b940521413c5f8428658`;
artifact `12534351515` (66,166,712 bytes) was fully saved and matched GitHub
SHA256 `25f1cf01c8d7f7e722e8c9f45ca03466a03d438c15231e170ff6cc3be1208faa`.
Root inspected PNGs `9877E4E5` and `E56A8D30`; the close-top image shows the
full surviving text and Composer above the visible keyboard. These focused
results validate the correction while leaving full-source and physical-device
acceptance separate.

The unchanged complete workflow
`40030625968` completed at exact source
`6767b64992f06b0efb25724b2412099f321a8a3b`. Hygiene job `120677719171`, all
1,317 Swift tests across 221 suites (160.695 seconds), and 20 XCTest units
passed. The actual iPad axis job `120677781096` passed in 91.195 seconds. The
Phone job `120677781200` executed 97 UI cases in 3,627.269 seconds: 95 passed,
one failed, and the expected Pad-only case was skipped. Close-top passed in
40.547 seconds; the sole failure was
`SkillsSettingsUITests.testLargestTypeSkillDetailsPortraitAndLandscape`
(48.591 seconds) at `ExtensionSettingsUITestSupport.swift:91`. There was no
host restart and one Swift Testing start. This preserves two distinct full
source REDs: the original `40009029013` at `6569707` failed close-top, while
`40030625968` passes close-top and fails the largest-type Skill Form viewport
check.

The Phone log is 3,989,227 bytes, SHA256
`cbee78a44548a5b530982b792e79d8fe4fbc32569723d3d01f6d30b9db192d27`. Artifact
`12538870056` (487,150,817 bytes) was fully downloaded and matched GitHub
SHA256 `7f98fc6174987cb15c4e2cfbcecb4db1a08357fed37787fcbf34ba2ee39b08a9`.
PNG `81D6AE61` and accessibility tree `3E67BB51` show the normal Form and its
read-only instruction near y=864.7. The failure log does not identify which
poll frame had an empty raw viewport; a later saved frame is composited and
valid. The prior helper broke immediately on its first empty raw viewport.

Harness-only candidate `a2548d88480e2e4ee704e085f7d9e42e783537a5` changes only
`Tests/ZenAgentUITests/ExtensionSettingsUITestSupport.swift`. It caches each
observed frame and continues with logging
through the original 24 polling attempts when a raw viewport is empty. Label
visibility, 44-point sizing, hit testing, drag checks, timeout and final
failure assertions remain unchanged. App source and App build inputs are
unchanged from `6767b64`; the same bounded reviewer approved the helper and
cached-frame ratio handling. Seven-case focused UI diagnostic
`40039765334` (diagnostic
`59571654946f9ee5133b66aeb08588b1a63f4149`, job `120707870583`) passed all 7
cases with 0 failures and 0 skips in 450.799 seconds, without a host restart.
The largest-type Skill details passed portrait and landscape in 134.327
seconds. Its 866,322-byte log SHA256 is
`b2197f8647896c825b8eceda7a939f1529483d54d360317a5a4ff8214b543005`. Artifact
`12538899177` (116,018,725 bytes) was fully downloaded and matched GitHub
SHA256 `e6f3f827400833d95ccfce018261daa87b8cba16fe779091b7046b19d5d8cf84`.
All 13 PNGs and 20 text files plus the manifest were audited; archive limits
are recorded in the ignored index. No `INVALID_SAMPLE` log appeared, so this
pass does not prove the empty-viewport recovery branch ran; it remains focused
evidence, not a full-gate result.

Third unchanged full workflow `40041705324` completed on exact source
`a2548d88480e2e4ee704e085f7d9e42e783537a5`. Swift Testing passed 1,317 tests
across 221 suites in 162.412 seconds; all 20 XCTest units passed. Phone UI
had 95 passes, 1 failure and 1 expected Pad-only skip in 3,212.843 seconds.
All 7 Stage 8 UI cases passed, including largest-type in 126.156 seconds;
close-top passed in 39.028 seconds and close-bottom in 37.517 seconds. The
actual iPad axis passed in 106.595 seconds. No host restart; one Swift Testing
start. The sole failure was the pre-existing Stage 6 case
`Stage6ToolUITests.testFileDisclosureConversationGrantAndSettingsRevocation`
(13.830 seconds), which had no keyboard focus after the initial tap/type and
did not reach Send or the grant assertion.

Phone log SHA256:
`A11BDDD0019DF43BF256ADC44B71BCA904F1EF37BB7A24FF1989A63C58FA2C29`; Pad log
SHA256: `62BC629869E59302D7BA94475568A2807FD7FA2FFF6A33AC16D3EFA3A3C882D0`.
Artifact `12541986022` (324,475,834 bytes) was fully saved and matched GitHub
SHA256 `c37c3e8391b8a78190a5ee17d75e31163b29d5bec41003ebb13a68b43420a5a4`.
The 8.96-second movie and AX state show `hasFocus=false` and
`keyboardFocus=false` at the observation point, with the first tap at
`(92, 801.375)` near the top edge. With no old probe fixture, the evidence
cannot distinguish a missed tap, occlusion or timing; no product-level cause
is claimed. This is the third full-source RED; the earlier REDs
`40009029013` and `40030625968` remain preserved. Manifest SHA256 for this run:
`5383A75C26E31115A64AA7E1EDF6B0087370C13F415549EC6F798F962010CC36`.

The one-file Stage 6 harness candidate
`def1fcd27f61e38acac02fa51c274664077b252b` adds the existing
`ZEN_SURFACE_LIFT_UI_TEST` flag in `Stage6ToolUITests`, preserving Stage 6 route priority
and product behavior. It
waits for the configured pane, lift readiness and sidebar availability before
the original single tap, then waits for real keyboard visibility, editor focus,
sidebar availability, hit testing and keyboard clearance before the original
`typeText` and Send/grant assertions. The current parser ignores historical
`liftTrace` values. There is no retry tap or fixed sleep, and existing timeouts
are unchanged. The bounded reviewer approved this helper. The App remains at
product source `6767b64`; configuration, workflow profile and budget are
unchanged. Focused Stage 6 UI run `40048092261` (diagnostic
`178dec9aa362e7e5adfa0e2debdd8e1b14310fdd`, job `120734331013`) passed all 6
UI cases, 0 failures and 0 skips in 304.269 seconds. The File grant case passed
in 81.186 seconds, without a host restart. Eight samples show four pre-tap
states with current surface/lift/sidebar true but keyboard/focus false, then
four post-tap states with keyboard/focus/sidebar true. No initial invalid
sample appeared, so this does not establish the prior failure's cause. The
863,592-byte log SHA256 is
`5eae22d82107b07c69caaa7c14376d769b0576c0881766dec538b173b1a93dcd`. Artifact
`12542807545` (120,698,831 bytes) was fully downloaded and matched GitHub
SHA256 `216554ab48e87aadd4b11794e705e0b8089cce9f724d9fd669ac9705fc4c0003`.
Manifest SHA256:
`087A4140F204E4B9A9EAA18B9F89333E03E87F1A664351F20FD08E8716FAA527`.

Fourth unchanged normal workflow `40049658208` completed successfully at exact
source `def1fcd27f61e38acac02fa51c274664077b252b`. Hygiene job `120739275266`,
Phone job `120739316941`, and Pad job `120739316955` all passed. Phone Swift
Testing passed 1,317 tests in 221 suites (188.115 seconds), all 20 XCTest units
passed, and the 97-case UI suite had 96 passes, one expected Pad-only skip, and
zero failures in 3,659.531 seconds. All 7 Stage 8 UI cases passed; largest
Skill took 132.188 seconds. There was one Swift Testing start, no host restart,
and `TEST SUCCEEDED` at 02:43:21 UTC. Phone raw log: 4,016,566 bytes, SHA256
`a6c649563f6ecc399d4ea4abc0c81d2234920affb13c86233e4475253eed1128`.

The Pad axis test
`testNativeAxisMenuPreservesBothEditorsAndSeparateRatios` passed in 93.485
seconds, without an actual skip or host restart. Raw
`final-pad-40049658208.log` is 970,734 bytes, SHA256
`588CCDD051A4B8631F3BA38F33D68D1ED25AF3D573592D3E7C3A3D593EC0EA8B`.
Artifact `12545351484` (457,093,283 bytes), GitHub SHA256
`5e142f1a893dd4130ca7716ebd5ceaefb80d702a374f00e04ab1cfa5ceb68eb6`, was fully
downloaded and matched locally. Manifest SHA256:
`087A4140F204E4B9A9EAA18B9F89333E03E87F1A664351F20FD08E8716FAA527`. Recorded
input identifiers: source tree `dcc282d09e59a147f87216b8ec6d39f7bd1075db`, App
`c15da60608fe46436ce9a9f4d0b11bec047d62ee`, Tests
`8b77c5f51f9e5d2b151ebaf27403907a73c1c032`. The native implementation gate is
complete. The final receipt changes only README, the evidence record and this
plan. App, Tests, Config, Resources, `.github` and `project.yml` retain the
tested blobs with the same manifest above. All three previous full REDs and
their SHA-matched native archives remain preserved.

Both Task 4 closeout checkboxes are complete. PR #43 and Blueprint PR #8 remain
draft/open/unmerged; physical-device acceptance remains open. Stage 9 has not
started, and no merge or package delivery is included.

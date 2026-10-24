# Stage 8 Skills and Environment evidence

Status: Stage 8 implementation and native gate complete on exact source
`def1fcd27f61e38acac02fa51c274664077b252b`. Physical-device acceptance remains
open; no merge or package delivery is claimed by this record.
Implementation [PR #43](https://github.com/54zhien/Zen-Agent/pull/43) is draft,
stacked on the separately unmerged Stage 7 PR #42.

Base: Stage 7 receipt `f335204b387e9a5ca10fa2091dbb24e4e3368296`, on
`codex/stage8-skills-environment-20261024`. Stage 7 PR #42 remains separately
draft/unmerged; Stage 8 does not merge it or enter Stage 9.

## Approved intent and implementation boundaries

The owner approved native Settings Forms for Skills and Environment, next-commit
manual selection owned by the Conversation draft, and Global defaults overridden
only by the active Skill's declared keys. The design decisions are recorded in
[Blueprint draft PR #8](https://github.com/54zhien/Zen-Agent-Blueprint/pull/8),
head `e17d65eb1a1e037cb9e4d80ec4208dcbea582fb1`, stacked on Blueprint PR #7.
This is design authorization, not native acceptance.

Environment and Skill revisions are immutable; Send atomically associates exact,
content-free references with the original Run. Ordinary edits preserve its
versions. Explicit deletion or disable revokes first, settles the original owner,
then removes data and retires owned credentials. Failed settlement or cleanup is
visible and retryable. Recovery preserves existing file-operation proof and never
replays a dispatched write.

Only a relevant bounded subset of enabled Skills enters a request; explicit
selection takes precedence over the local router. Workflow text is untrusted
user context and cannot grant Tool permissions, increase exposure, or bypass
policy/approval. Scoped plain interpolation is bounded and rejects unknown keys,
cycles and Secret interpolation. Secret bytes are available only to trusted
credential/validation/execution seams; snapshots contain opaque references.

## Native development evidence

Focused diagnostic children change only the workflow selector and skip Pad;
their App, Tests, resources, configuration and project inputs match their stated
source commit. They are not the original full Phone/Pad gate. Failed runs remain
available under their original refs; no unchanged rerun is used as correction.

| Native run | Source | Actual conclusion |
|---|---|---|
| [39988029803](https://github.com/54zhien/Zen-Agent/actions/runs/39988029803) | `d6fbfe7` | App/XcodeGen passed; 1,276 Swift tests, 203 suites, intentional Environment schema/service RED 9; 20 XCTest passed. |
| [39990383415](https://github.com/54zhien/Zen-Agent/actions/runs/39990383415) | `be08634` | App passed; 1,277 Swift tests, intentional orphan-cleanup RED 2 plus existing streaming-fixture failure 1. Original Environment cases passed. |
| [39990785863](https://github.com/54zhien/Zen-Agent/actions/runs/39990785863) | `426565a` | App passed; 1,281 Swift tests, intentional orphan/schema RED 6 only. |
| [39991419430](https://github.com/54zhien/Zen-Agent/actions/runs/39991419430) | `3f2ca54` | App/test compilation passed; 1,285 Swift tests, intentional orphan/schema/Skill-service RED 10. Both actual management UI entries RED. |
| [39994385716](https://github.com/54zhien/Zen-Agent/actions/runs/39994385716) | `9b3284b` | App/test compilation passed; 23 Swift tests in 6 suites, behavioral RED 11 across draft consumption, actual Send, payload conflict and cold original-owner recovery. |
| [39995345439](https://github.com/54zhien/Zen-Agent/actions/runs/39995345439) | `3a8e24c` | App/test compilation passed; 22 Swift tests in 6 suites, Environment/orphan/scoped resolver/Skill lifecycle/snapshot/real-socket streaming GREEN. One authority test had an incorrect successful-Run expectation; its security assertions already passed. |
| [39996964522](https://github.com/54zhien/Zen-Agent/actions/runs/39996964522) | `c1d4e28` | App/test compilation passed; 35 Swift tests in 9 suites GREEN, including draft selection, actual requests, payload conflict and cold Skill/file-proof settlement. |
| [39998482466](https://github.com/54zhien/Zen-Agent/actions/runs/39998482466) | `bde5cf9` | 10 Swift tests in 4 suites; actual recovered Run gained a newly registered Tool despite empty frozen exposure, RED 2. Other authority/Secret cases passed. |
| [40000509025](https://github.com/54zhien/Zen-Agent/actions/runs/40000509025) | `f55c42c` | 11 Swift tests in 5 suites GREEN: exact frozen exposure, result redaction, live approval and three queued revocations. |
| [39996935302](https://github.com/54zhien/Zen-Agent/actions/runs/39996935302) | `c1d4e28` | 6 native UI cases: 3 passed, 3 failed in confirmation query/Form gestures; no plugin behavior reached. Actual screenshots, AX and full failed archive retained. |
| [40001312420](https://github.com/54zhien/Zen-Agent/actions/runs/40001312420) | `fc23aed` | 5 native UI cases: Environment 3 and Skills entry passed; largest-text detail asserted before its lazy instruction row was scrolled into the AX hierarchy. |
| [40002938531](https://github.com/54zhien/Zen-Agent/actions/runs/40002938531) | `8944664` | Configured Composer reached the actual plugin row; 1 native UI case RED because the entry remained disabled. |
| [40003222328](https://github.com/54zhien/Zen-Agent/actions/runs/40003222328) | `4e58030` | App/test compilation passed; 8 Swift tests in 4 suites, behavioral RED 15 across content commit races, ambiguous provisioning, handoff ordering and retained Provider credentials. |
| [40005275452](https://github.com/54zhien/Zen-Agent/actions/runs/40005275452) | `a2f4c5d` | App/test compilation passed; all 7 native management/Composer UI cases GREEN in 551.885 seconds. |
| [40006020779](https://github.com/54zhien/Zen-Agent/actions/runs/40006020779) | `2f3d9ab` | 1,314 Swift tests in 220 suites, 4 issues in 169.393 seconds; 20 XCTest units passed. All three Important review regressions GREEN; two stale Composer source contracts and one Files continuation regression remained. |
| [40009039542](https://github.com/54zhien/Zen-Agent/actions/runs/40009039542) | `6569707` | App/XcodeGen/test compilation passed; 24 Swift tests in 4 suites GREEN in 2.978 seconds, including the real Files positive path, three negative controls, Composer contracts and actual queued-writer handoff readiness. |
| [40009029013](https://github.com/54zhien/Zen-Agent/actions/runs/40009029013) | `6569707` | Original complete workflow FAILED: 1,314 Swift tests/220 suites and 20 XCTest units passed; Phone 95 passed, 1 failed, 1 expected Pad-only skip. All 7 Stage 8 UI cases passed. Actual iPad axis passed separately. One Swift start and no host restart; the sole failure was the surviving editor text assertion after explicit close-top; trace `40022375226` later confirmed the local keyboard-guide geometry defect. The original source remains failed; corrected-source validation is recorded separately. |
| [40020606905](https://github.com/54zhien/Zen-Agent/actions/runs/40020606905) | `8281f66` | App/test compilation passed; 3 focused UI cases, 2 passed and close-top failed its new pre-input compound readiness condition. The original immediate full-string assertion passed afterward. No timeout or post-input assertion was changed; the compound gate needs runtime diagnosis. |
| [40022375226](https://github.com/54zhien/Zen-Agent/actions/runs/40022375226) | `9f019a9` | Focused live trace: bottom passed; close-top failed after 91.424 seconds with keyboard/focus true but the local guide empty and measured gap `-289` against 12 pt spacing; the actual Composer was obscured. Diagnostic RED, not a full-gate result. |
| [40028246136](https://github.com/54zhien/Zen-Agent/actions/runs/40028246136) | `6767b64` / diag `48f1fecc` | Focused GREEN: 28 Swift tests/3 suites in 30.075 seconds and 3 UI cases passed (89.654 seconds total), with no skips, failures or host restarts. Log SHA256 `f35a631ccf06f41f8164b2b2986371a24718123f511eb644cf67bf80abb37173`; artifact `12533909454` (101,010,111 bytes), full download SHA256 `b7dc8283f2789913ff5c248cfd2c195b3c8cb37584fd5cd87187ab78fef2a67a` matched. |
| [40028277525](https://github.com/54zhien/Zen-Agent/actions/runs/40028277525) | `6767b64` / diag `a498b7f9` | Supplemental actual Source-bottom UI control GREEN: 1 case passed in 49.958 seconds. Log SHA256 `00e4e40357a187f3503bdf1ba5af200ee58a0462d498b940521413c5f8428658`; fully saved artifact `12534351515` (66,166,712 bytes), GitHub SHA256 `25f1cf01c8d7f7e722e8c9f45ca03466a03d438c15231e170ff6cc3be1208faa` matched. |
| [40030625968](https://github.com/54zhien/Zen-Agent/actions/runs/40030625968) | `6767b64` | Second unchanged full-source run: hygiene, all 1,317 Swift tests/221 suites (160.695 s) and 20 XCTest units passed; actual iPad axis passed in 91.195 s. Phone UI had 95 passes, 1 failure and 1 expected Pad-only skip in 3,627.269 s; sole failure was `SkillsSettingsUITests.testLargestTypeSkillDetailsPortraitAndLandscape` (48.591 s), where the viewport helper exited on its first empty raw sample. No host restart; one Swift test start. Log 3,989,227 bytes, SHA256 `cbee78a44548a5b530982b792e79d8fe4fbc32569723d3d01f6d30b9db192d27`; artifact `12538870056` (487,150,817 bytes), fully downloaded and matched SHA256 `7f98fc6174987cb15c4e2cfbcecb4db1a08357fed37787fcbf34ba2ee39b08a9`. Full gate remains failed. |
| [40039765334](https://github.com/54zhien/Zen-Agent/actions/runs/40039765334) | `a2548d8` / diag `59571654946f9ee5133b66aeb08588b1a63f4149` | Focused GREEN: 7 UI cases passed, 0 failures/0 skips in 450.799 s; no host restart. Largest-type Skill details passed portrait and landscape in 134.327 s. No `INVALID_SAMPLE` log appeared, so this run did not exercise or prove the empty-viewport recovery branch. Job `120707870583`; log 866,322 bytes, SHA256 `b2197f8647896c825b8eceda7a939f1529483d54d360317a5a4ff8214b543005`. Artifact `12538899177` (116,018,725 bytes) fully downloaded; SHA256 `e6f3f827400833d95ccfce018261daa87b8cba16fe779091b7046b19d5d8cf84` matched. All 13 PNGs and 20 text files plus manifest were audited; detail limits are in the ignored index. Focused only, not a full gate. |
| [40041705324](https://github.com/54zhien/Zen-Agent/actions/runs/40041705324) | `a2548d8` | Third unchanged full run: 1,317 Swift tests/221 suites (162.412 s) and 20 XCTest units passed; all 7 Stage 8 UI cases passed, including largest-type in 126.156 s. Phone UI had 95 passes, 1 failure and 1 expected Pad-only skip in 3,212.843 s; sole failure was pre-existing `Stage6ToolUITests.testFileDisclosureConversationGrantAndSettingsRevocation` (13.830 s), which had no keyboard focus after the initial tap/type and never reached Send or grant. Close-top (39.028 s), close-bottom (37.517 s) and actual iPad axis (106.595 s) passed. No host restart; one Swift test start. Phone log 4,013,033 bytes, SHA256 `A11BDDD0019DF43BF256ADC44B71BCA904F1EF37BB7A24FF1989A63C58FA2C29`; Pad log 966,199 bytes, SHA256 `62BC629869E59302D7BA94475568A2807FD7FA2FFF6A33AC16D3EFA3A3C882D0`. Artifact `12541986022` (324,475,834 bytes), fully downloaded and matched SHA256 `c37c3e8391b8a78190a5ee17d75e31163b29d5bec41003ebb13a68b43420a5a4`. Historical full RED. |
| [40048092261](https://github.com/54zhien/Zen-Agent/actions/runs/40048092261) | `def1fcd` / diag `178dec9aa362e7e5adfa0e2debdd8e1b14310fdd` | Focused GREEN: 6 UI cases passed, 0 failures/0 skips in 304.269 s; File grant case passed in 81.186 s, no host restart. Eight samples show four pre-tap states with current surface/lift/sidebar available but keyboard/focus false, then four post-tap states with keyboard/focus/sidebar true. No initial invalid sample, so this does not prove the prior missed-focus cause. Job `120734331013`; log 863,592 bytes, SHA256 `5eae22d82107b07c69caaa7c14376d769b0576c0881766dec538b173b1a93dcd`. Artifact `12542807545` (120,698,831 bytes) fully downloaded and matched SHA256 `216554ab48e87aadd4b11794e705e0b8089cce9f724d9fd669ac9705fc4c0003`. |
| [40049658208](https://github.com/54zhien/Zen-Agent/actions/runs/40049658208) | `def1fcd27f61e38acac02fa51c274664077b252b` | Fourth unchanged normal full workflow SUCCESS: hygiene `120739275266`, Phone `120739316941`, Pad `120739316955` all passed. Phone: 1,317 Swift tests/221 suites in 188.115 s, 20 XCTest units passed, 97 UI (96 pass/1 expected Pad-only skip/0 fail) in 3,659.531 s; all 7 Stage 8 UI passed, largest Skill 132.188 s; one Swift Testing start, no host restart, TEST SUCCEEDED 02:43:21 UTC. Phone raw log 4,016,566 bytes, SHA256 `a6c649563f6ecc399d4ea4abc0c81d2234920affb13c86233e4475253eed1128`. Pad: `testNativeAxisMenuPreservesBothEditorsAndSeparateRatios` passed in 93.485 s; no actual skip/restart. Pad raw log 970,734 bytes, SHA256 `588CCDD051A4B8631F3BA38F33D68D1ED25AF3D573592D3E7C3A3D593EC0EA8B`. Artifact `12545351484` (457,093,283 bytes), GitHub SHA256 `5e142f1a893dd4130ca7716ebd5ceaefb80d702a374f00e04ab1cfa5ceb68eb6`, fully downloaded and locally matched. Manifest `087A4140F204E4B9A9EAA18B9F89333E03E87F1A664351F20FD08E8716FAA527`; source tree `dcc282d09e59a147f87216b8ec6d39f7bd1075db`, App `c15da60608fe46436ce9a9f4d0b11bec047d62ee`, Tests `8b77c5f51f9e5d2b151ebaf27403907a73c1c032`. Native implementation gate complete; the three-file receipt preserves the tested build-input manifest. |


The streaming failure used the pre-existing small-open-body URLProtocol fixture;
existing characterization tests already show that fixture can withhold the first
small chunk. Only the affected test now uses the characterized local HTTP socket
with the same 400 ms liveness limit, 200 ms progress limit and assertion. No
production transport timeout was widened. The failed run remains evidence.

Test compilation failures are distinct from behavioral RED: `39992789922`,
`39993262190`, `39993364732` hit Swift Testing throwing lookup macro expansion;
`39994836997` used equality on a non-Equatable settings DTO. Corrections evaluate
throwing lookups separately and compare stable grant IDs. `39997664130` contains
two later throwing-constructor test errors; the corrected source is `bde5cf9`.
None is represented as a passing or executed behavioral test.

Completed logs, hashes, diagnostic/source identities and native artifacts are
retained in the ignored Stage 8 evidence directory and in GitHub Actions.
The frozen-Send GREEN log SHA256 is
`4738FD26E670A9FBF24F3C70DC74D4712AB92C60D80DFB570DD2CAB9384AF029`.

## Rulings and costs

The one independent whole-branch review covers base `f335204` through the final
source, including the actual Composer wiring. Its three Important findings were
reproduced through the production owners in run `40003222328` before correction:

1. A newly saved Environment Secret could overtake an old secret inventory before
   Plain, Skill, manual/automatic Memory or ToolResult committed. The corrective
   boundary serializes validation/redaction through the SQLite commit, and Secret
   publication takes the existing exclusive handoff lease. Every Provider handoff
   also re-sanitizes only outgoing ToolResult copies against the current inventory;
   an earlier legal result is retained as history without replaying its executor.
2. CredentialStore could keep freshly owned Keychain bytes when metadata publication
   and its verification read both failed, leaving no metadata row for startup scans.
   A durable content-free ownership reservation precedes provisioning and clears in
   the same transaction that attaches its revision. Pending cleanup may delete only
   that owned Environment reference/generation, including after database reopening.
3. Reauthentication deliberately retains an old Key for frozen Runs, but the current
   Provider attachment omitted it from content validation. Trusted inventory now
   includes retained active metadata, nonterminal frozen bindings and pending owned
   Environment retirements. It never becomes a workflow/executor input.

The three Important corrections are native GREEN in `40006020779`, including
real disk reopening after ambiguous provisioning, all five content-commit races
and actual reauthentication. That broader all-unit gate still failed for the
separate contracts/continuation issues above. The original RED log SHA256 is
`7A5405952F5F7CF58195E05E503F4BC6EFC333A6327B6477B4C10FE08AF4CB96`.
The pre-existing Provider credential-mutation concurrency protocol is explicitly
declined-to-judge in this Stage 8 review: those Stage 7 writers are unchanged and
no before/after regression was demonstrated. This is not a claim that they have
the new Environment publication transaction's guarantees.

The native plugin UI case covers opening/selection; durable actual Send and
continuation behavior are exercised by the native runtime/coordinator tests.
Do not represent the UI selection case alone as a UI-to-network Send test.

The all-unit Files failure retained the committed effect and its immutable receipt,
but unconditional outgoing inventory reading blocked its fixed result-withheld
notice when protected credentials became unreadable. The correction exempts only
the exact fixed UTF-8 notice backed by the current Run's unique succeeded call,
matching durable result and same-attempt/intent-binding file receipt. It sends no
receipt payload. Same-text unproven calls, suffixes and mixed unknown results still
require readable inventory. Existing request/result assertions and timing remain;
new negative controls verify the exception cannot admit arbitrary content. The
same reviewer checked this bounded correction. The obsolete Composer contracts
now explicitly include the approved draft IDs and the active Skill menu while
retaining the image/file and model-catalog assertions.

The review's Minor handoff-test readiness issue is corrected: a DEBUG-only read
of the real gate's waiting writers replaces the fixed 100 scheduler yields. The
test must observe the actual queued writer, then still verifies no early save,
an empty variable list and the real Provider request after release. It cannot
pass solely because the saving task was delayed. The same reviewer checked this
bounded correction; Release gate scheduling is unchanged. The stronger test and
the Files correction are native GREEN in focused run `40009039542`; its log
SHA256 is `008A4632D8254A9031F8385FAF02E5B0DA3A38B197A14520A8CA3555867AAEB2`.
The retained native archive is artifact `12527050481`, 172,532 bytes, SHA256
`49caa25e41029cbb9eb8dd4168bcd4e2727fc46a4e290b42350e11677cc7b75b`.

The `alreadyExists`/failed-reservation-clear foreign-reference scenario is
explicitly declined: production creates the fresh opaque Environment UUID inside
the shared lock, checks metadata absence before reservation, and exposes no
caller-selected reference. Provider allocators use API-key references. Future
import or externally specified Environment references require a new durable
ownership design rather than inheriting this allocation proof.

The complete failed native archives are retained locally with GitHub-matching
SHA256 digests: `39996935302` (`1a3c8e56…`), `40001312420` (`d43c7e7e…`),
`40002938531` (`cc002c6f…`) and `40003222328` (`8f65f77b…`). Full digests,
byte counts and original artifact IDs are in the retained evidence ledger.

- Stage 8 ships real Keychain storage, versioned bindings and a trusted resolver.
  Existing tools have no authenticated Secret input; MCP belongs to Stage 9.
  Cost: saved Secrets have no authenticated production action yet, disclosed in
  Settings. No fake secret-consuming executor is introduced.
- Ordinary Secret edits use fresh opaque references. Cost: retained historical
  bindings consume Keychain storage until explicit deletion. The pruning concern
  is declined as a bug because non-erased frozen revisions remain valid even without
  a nonterminal Run; automatic pruning would change that contract. Explicit erasure
  remains stronger than replay.
- Classifying bytes as a Secret is prospective. Cost: saving a Secret cannot
  retract ordinary content already recorded while those bytes were public.
  Future trusted Skill/Memory writes validate the current inventory and outgoing
  ToolResult copies are re-sanitized; existing explicit user/model history is
  not globally rewritten.
- Scope and key are immutable identity. Cost: rename/move uses explicit
  dependency-aware delete/add rather than changing frozen reference meaning.
- Revocation and final removal straddle original-owner settlement outside the
  shared gate. Cost: failed settlement/Keychain retirement requires visible retry.
- New snapshots use v2; new builds read legacy v1 without Skills. Cost: old builds
  must reject v2 rather than silently resume a Run without its Skill semantics.
- Built-ins and copied definitions are disabled until explicitly enabled. Cost:
  one enable action; installation alone does not inject all workflows.
- Bounded UI work was delegated only after actual native management-entry RED;
  core wiring, source commits and verification remained with the owner agent.
  Pure contract work during CI waits was provisional until native tests ran.

## Native UI inspection

All 13 PNG captures from native run `40005275452` were visually inspected,
alongside its text/manifest attachments. They cover light management Forms,
editable instructions and keyboard, the saved/enabled user Skill, the enabled
Composer plugin entry, dark masked Secret input and blank replacement editor,
dependency-aware deletion confirmation, and largest-text portrait/landscape
instructions and Environment pickers. The full archive is artifact `12525242413`,
12,867,707 bytes, SHA256
`720412883c2441e0850a2d563577dd25159ac8b93f3831fa0a0660f120b9d696`.

Some preview captures contain the existing DEBUG older-turn-position overlay;
that fixture limits production pixel/layout conclusions. The post-selection
capture is after menu closure and supports the accessibility selection count,
not a claim of a captured visible submenu checkmark or a new badge. Preview's
empty Tool registry explains its missing-dependency labels; production Settings
and Conversation receive the existing real registry from AppAssembly. Actual
Send and frozen continuation are covered by runtime/coordinator tests, separately
from the UI save/enable/select case. No physical-device acceptance is inferred.

## Original complete source gate (failed)

The unchanged normal workflow [40009029013](https://github.com/54zhien/Zen-Agent/actions/runs/40009029013)
uses source `6569707dd8f4acefa3675eae81703508d9e906ba`, tree
`b94da5d91044647d870f65a994d61b456237e81d`. Hygiene job `120604298368` passed.
Actual iPad job `120604387003` passed
`testNativeAxisMenuPreservesBothEditorsAndSeparateRatios` in 105.889 seconds,
with no skipped test or host restart. Its saved raw log SHA256 is
`503DA9C942C943C5BCA1F75DB3793C5616CFC3E9124D1D20347B2C93B635B90C`.
Phone job `120604386825` failed only at
`SplitResizeUITests.testExplicitCloseTopKeepsTheSecondaryConversationEditable`,
line 151, after typing into the surviving editor. All preceding close/identity/
single-editor assertions passed. The Phone suite executed 97 UI tests in
3,739.498 seconds: 95 passes, 1 failure and 1 expected Pad-only skip. All 7 new
Stage 8 UI cases passed. Swift Testing executed once: 1,314 tests/220 suites
passed in 161.319 seconds, alongside 20 passing XCTest units and no host restart.
This failed full gate is retained, not replaced by focused results. The saved
Phone log SHA256 is
`261e7016f134dd7b9cc03aad342748fa4d58df791efb5df2061a944decf9cee4`.
Its native archive is artifact `12528854883`, 468,102,305 bytes, GitHub SHA256
`7c32ec5b111f0283058e32157134f96714f0d352b208610e77aebd5ff661993e`.
All failed native bytes were saved and their digest matched GitHub. The recording
shows an expanded editor before the keyboard is visible, then the actual text
growing from `survivor after e` to `survivor after explic` near the failure. It
does not establish a final full value. Exported AX snapshots contain only the
application root; synthesized events prove the full injected string but not its
successful completion. The original close/owner paths are unchanged from the base.

Test-only candidate `8281f66` added a pre-input keyboard/focus/current-anchor gate
using the existing 10-second waiter, leaving the original string and immediate
post-input assertion intact. Focused run `40020606905` timed out that compound
condition only for close-top; the original full-string assertion then passed.
This is not a GREEN correction. Its log SHA256 is
`27c81b3ebbafc9191a6b4fe4b6dc4dc48fbfc5a69899b65b1d833c68a5f7002c`;
artifact `12531420853` is 80,331,696 bytes, GitHub SHA256
`bb648ef8221fa29d09670941b69e30ee4bf22de0d639851cfed3b6d84c6088ed`.
Source `9f019a9` adds only live precondition tracing for diagnosis; it does not
change those conditions or timeouts. No new complete source gate is claimed.

## Retained Composer keyboard-anchor diagnosis and correction

Focused native run [40022375226](https://github.com/54zhien/Zen-Agent/actions/runs/40022375226)
used source `9f019a9981b758a580a2eaae8f27fef73585e26b`, trace diagnostic
`24358bbca6eb367b27042e0d2b7ac6a396f4d77c`, and Phone job `120649972421`.
The bottom control passed; close-top failed after 91.424 seconds. The retained
log is 841,144 bytes, SHA256
`840e2633e63b37b559a30738cbd72ca885f12c48b04b17b76b33e39af88b355b`.
Native archive `12532498422` is 104,790,242 bytes, GitHub SHA256
`4daad1f2647d301d1fc7c84e08a9a24c6f80a2c74222bc3d3f93039fedd28c9a`.

The compact field capture contains eight repeated top samples with keyboard
visible, editor focused, and `settled=false`, plus one valid bottom sample
and one teardown sample with no editor. In each top sample the retained portal's
local guide was `(0, 778, 0, 0)`, the converted active guide was
`(0, 477, 402, 335)`, and the root guide was `(0, 539, 402, 335)`. The local
bottom constraint remained active. Its measured gap was `-289` against
12-point spacing; the Composer surface was `(16, 642, 370, 124)` and editor
window frame `(28, 718, 346, 58)`. The saved frame-84 capture shows the visible
keyboard obscuring the Composer. This confirms a real stale-portal geometry
defect; the readiness timeout was not merely an over-strict test gate.

Source commit `6767b64992f06b0efb25724b2412099f321a8a3b` keeps the existing
local keyboard constraint and the same `UITextView`. `ComposerHostView` observes
the active root keyboard guide with a hidden, noninteractive, accessibility-hidden
probe; on geometry change it clears the cached active/local frames and requests
normal host layout so the existing offset reconciliation can use the current
root geometry. Rebinding invalidates the old observer. The correction does not
replace the editor or change focus, keyboard animation, or motion policy.
`SplitResizeUITests` retains its pre-input readiness gate and original full-string
assertion, adding reachability/above-keyboard checks and a screenshot capture.
Controlled-layout-guide unit tests cover frame changes, origin-only movement,
stable geometry, and invalidation. The same bounded reviewer checked the Host and
Observer change and found no material lifecycle, reentry, accessibility, or
motion issue; this is source review, not native acceptance.

Focused run [40028246136](https://github.com/54zhien/Zen-Agent/actions/runs/40028246136)
used source `6767b64992f06b0efb25724b2412099f321a8a3b`, diagnostic
`48f1fecc95ed5f151426ac260721d21f19d72f0b`, and Build and test job
`120669792003`. XcodeGen/App build passed; 28 Swift tests in 3 suites passed in
30.075 seconds, and all 3 selected UI cases passed in 89.654 seconds:
`testDragClosureKeepsFocusedSecondaryAndAllowsTheFirstSidebarSwipe` (50.136 s),
`testExplicitCloseTopKeepsTheSecondaryConversationEditable` (39.420 s), and
`testLiveComposerReceiptIgnoresHistoricalEligibility` (0.098 s). There were no
skips, failures, or host restarts. The retained log is 805,210 bytes, SHA256
`f35a631ccf06f41f8164b2b2986371a24718123f511eb644cf67bf80abb37173`. Artifact
`12533909454` is 101,010,111 bytes; its complete download matched GitHub SHA256
`b7dc8283f2789913ff5c248cfd2c195b3c8cb37584fd5cd87187ab78fef2a67a`. The
workflow's extra Bottom selector named a nonexistent Primary-case variant, so
the actual bottom control was checked separately.

Supplemental run [40028277525](https://github.com/54zhien/Zen-Agent/actions/runs/40028277525)
used the same source, diagnostic
`a498b7f91446f3a3162c18569d07ccec7b513de3`, and job `120669913679`. The
actual `testExplicitCloseBottomKeepsTheSourceConversationEditable` control
passed in 49.958 seconds, with no skips, failures, or host restarts. Its log is
693,447 bytes, SHA256
`00e4e40357a187f3503bdf1ba5af200ee58a0462d498b940521413c5f8428658`. Artifact
`12534351515` is 66,166,712 bytes, fully saved with matching GitHub SHA256
`25f1cf01c8d7f7e722e8c9f45ca03466a03d438c15231e170ff6cc3be1208faa`. Both
diagnostic workflows differ only in CI test selection. Root inspected PNGs
`9877E4E5` and `E56A8D30`: the close-top capture contains the full surviving
editor text and shows the Composer above the visible keyboard. These focused
GREEN results verify the bounded correction; they do not replace the complete
source gate or establish physical-device acceptance.

The unchanged normal `workflow_dispatch` run
[40030625968](https://github.com/54zhien/Zen-Agent/actions/runs/40030625968)
completed from source `6767b64992f06b0efb25724b2412099f321a8a3b`. Hygiene job
`120677719171` passed. Build/test job `120677781200` reported 1,317 Swift
tests across 221 suites passing in 160.695 seconds and 20 XCTest units passing.
The Phone UI executed 97 cases in 3,627.269 seconds: 95 passed, 1 failed and
the expected Pad-only case was skipped. The sole failure was
`SkillsSettingsUITests.testLargestTypeSkillDetailsPortraitAndLandscape` after
48.591 seconds at `ExtensionSettingsUITestSupport.swift:91`; the actual iPad
axis job `120677781096` passed in 91.195 seconds. The independent close-top
case passed in 40.547 seconds. There was no host restart and one Swift Testing
start. Thus this is a second complete-source RED: the earlier full run
`40009029013` at `6569707` still records the close-top failure, while this run
passes close-top and fails the largest-type Skill Form viewport check.

The 3,989,227-byte Phone log SHA256 is
`cbee78a44548a5b530982b792e79d8fe4fbc32569723d3d01f6d30b9db192d27`. Artifact
`12538870056` (487,150,817 bytes) was fully downloaded and matched GitHub
SHA256 `7f98fc6174987cb15c4e2cfbcecb4db1a08357fed37787fcbf34ba2ee39b08a9`.
The saved PNG and accessibility tree (`81D6AE61`, `3E67BB51`) show the expected
Form and its read-only instruction near y=864.7. The failure log did not retain
which exact poll frame had an empty raw viewport; a later saved frame was
composited and valid. The harness guard stopped immediately on its first empty
raw viewport sample.

Harness-only candidate source
`a2548d88480e2e4ee704e085f7d9e42e783537a5` changes only
`Tests/ZenAgentUITests/ExtensionSettingsUITestSupport.swift`. It
caches each observed frame and continues, with logging, through the original
24 polling attempts when the raw viewport is temporarily empty. Label
visibility, 44-point sizing, hit testing, drag checks, timeout, and final
failure assertions remain unchanged. App source and App build inputs are
unchanged from `6767b64`; the same bounded reviewer approved the helper and its
cached-frame ratio handling. Seven-case focused run
[40039765334](https://github.com/54zhien/Zen-Agent/actions/runs/40039765334),
diagnostic `59571654946f9ee5133b66aeb08588b1a63f4149`, passed all 7 UI cases
with 0 failures and 0 skips in 450.799 seconds; there was no host restart.
`SkillsSettingsUITests.testLargestTypeSkillDetailsPortraitAndLandscape` passed
in 134.327 seconds across portrait and landscape. Job `120707870583` log is
866,322 bytes, SHA256
`b2197f8647896c825b8eceda7a939f1529483d54d360317a5a4ff8214b543005`. Artifact
`12538899177` (116,018,725 bytes) was fully downloaded and matched GitHub
SHA256 `e6f3f827400833d95ccfce018261daa87b8cba16fe779091b7046b19d5d8cf84`.
All 13 PNGs, 20 text files and the manifest were audited; archive limits are
recorded in the ignored index. No `INVALID_SAMPLE` log appeared, so this
focused GREEN does not demonstrate that the empty-viewport recovery branch was
exercised. It remains focused evidence, not a full-gate result.

The third unchanged normal full workflow
[40041705324](https://github.com/54zhien/Zen-Agent/actions/runs/40041705324)
completed on exact candidate source
`a2548d88480e2e4ee704e085f7d9e42e783537a5`. Swift Testing passed 1,317 tests
across 221 suites in 162.412 seconds, and all 20 XCTest units passed. Phone UI
executed 97 cases in 3,212.843 seconds: 95 passed, 1 failed and 1 expected
Pad-only case was skipped. All 7 Stage 8 UI cases passed, including largest
type in 126.156 seconds; close-top passed in 39.028 seconds and close-bottom
in 37.517 seconds. Actual iPad axis job passed in 106.595 seconds. There was no
host restart and one Swift Testing start. The sole Phone failure was the
pre-existing Stage 6 UI case
`Stage6ToolUITests.testFileDisclosureConversationGrantAndSettingsRevocation`
(13.830 seconds): its initial tap/type did not establish focus, so it never
reached Send or the grant assertion.

The Phone log is 4,013,033 bytes, SHA256
`A11BDDD0019DF43BF256ADC44B71BCA904F1EF37BB7A24FF1989A63C58FA2C29`; the Pad
log is 966,199 bytes, SHA256
`62BC629869E59302D7BA94475568A2807FD7FA2FFF6A33AC16D3EFA3A3C882D0`. Artifact
`12541986022` (324,475,834 bytes) was fully saved and matched GitHub SHA256
`c37c3e8391b8a78190a5ee17d75e31163b29d5bec41003ebb13a68b43420a5a4`. The
8.96-second movie and AX evidence show `hasFocus=false` and
`keyboardFocus=false` at the observed point, with the first tap at `(92,
801.375)` near the top edge. There is no old probe fixture, and the evidence
does not determine whether a missed tap, occlusion or timing caused the lack
of keyboard focus; no product-level conclusion is drawn. This is the third distinct
full-source RED. The first two, `40009029013` and `40030625968`, remain
preserved. The tested-input manifest SHA256 for `40041705324` is
`5383A75C26E31115A64AA7E1EDF6B0087370C13F415549EC6F798F962010CC36`; the prior
`6767b64` manifest remains
`AAB1CB093439DC5C2A44B8E19BA782E0D357D611EA990E830458AE55EF3BDAB5`.

The one-file follow-up candidate
`def1fcd27f61e38acac02fa51c274664077b252b` changes only
`Stage6ToolUITests` and adds the existing `ZEN_SURFACE_LIFT_UI_TEST` flag while
preserving Stage 6 route priority and product behavior. It waits for the
configured pane, lift readiness and sidebar availability before the original
single tap. After
that tap it waits for real keyboard visibility, actual editor focus, sidebar
availability, hit testing and keyboard clearance; the original `typeText` and
Send/grant assertions remain. The current field parser ignores historical
`liftTrace` values. It adds no tap retry or fixed sleep and changes no existing
timeouts. The same bounded reviewer approved the candidate; the App remains at
the `6767b64` product source, and no configuration, workflow profile or budget
changed. Focused full Stage 6 UI run
[40048092261](https://github.com/54zhien/Zen-Agent/actions/runs/40048092261)
(diagnostic `178dec9aa362e7e5adfa0e2debdd8e1b14310fdd`, job
`120734331013`) passed all 6 UI cases, with 0 failures and 0 skips in 304.269
seconds. The File grant case passed in 81.186 seconds; there was no host
restart. Eight native samples contain four pre-tap observations with current
surface/lift/sidebar available while keyboard/focus were false, and four
post-tap observations with keyboard/focus/sidebar true. There was no initial
invalid sample in this run, so it does not establish the cause of the earlier
failed run. The 863,592-byte log SHA256 is
`5eae22d82107b07c69caaa7c14376d769b0576c0881766dec538b173b1a93dcd`. Artifact
`12542807545` (120,698,831 bytes) was fully downloaded and matched GitHub
SHA256 `216554ab48e87aadd4b11794e705e0b8089cce9f724d9fd669ac9705fc4c0003`.
The tested-source manifest SHA256 is
`087A4140F204E4B9A9EAA18B9F89333E03E87F1A664351F20FD08E8716FAA527`.

## Final unchanged full-source gate (native implementation GREEN)

Fourth unchanged normal full run
[40049658208](https://github.com/54zhien/Zen-Agent/actions/runs/40049658208)
completed successfully from exact source
`def1fcd27f61e38acac02fa51c274664077b252b`. Hygiene job `120739275266`, Phone
job `120739316941` and Pad job `120739316955` all passed. Phone Swift Testing
passed 1,317 tests across 221 suites in 188.115 seconds; all 20 XCTest units
passed. The Phone UI ran 97 cases in 3,659.531 seconds: 96 passed, 1 expected
Pad-only case was skipped and 0 failed. All 7 Stage 8 UI cases passed,
including largest Skill in 132.188 seconds. There was one Swift Testing start,
no host restart, and `TEST SUCCEEDED` at 02:43:21 UTC.

The Phone raw log is 4,016,566 bytes, SHA256
`a6c649563f6ecc399d4ea4abc0c81d2234920affb13c86233e4475253eed1128`. Pad
`testNativeAxisMenuPreservesBothEditorsAndSeparateRatios` passed in 93.485
seconds, with no actual skip or host restart. The raw
`final-pad-40049658208.log` is 970,734 bytes, SHA256
`588CCDD051A4B8631F3BA38F33D68D1ED25AF3D573592D3E7C3A3D593EC0EA8B`.
Artifact `12545351484` (457,093,283 bytes), GitHub SHA256
`5e142f1a893dd4130ca7716ebd5ceaefb80d702a374f00e04ab1cfa5ceb68eb6`, was fully
downloaded and matched locally. Manifest SHA256:
`087A4140F204E4B9A9EAA18B9F89333E03E87F1A664351F20FD08E8716FAA527`.
Recorded input identifiers are source tree
`dcc282d09e59a147f87216b8ec6d39f7bd1075db`, App
`c15da60608fe46436ce9a9f4d0b11bec047d62ee`, and Tests
`8b77c5f51f9e5d2b151ebaf27403907a73c1c032`. The native implementation gate
is complete. The final receipt changes only README, this record and the
implementation plan; App, Tests and build inputs retain the tested blobs.

## Final receipt and acceptance boundary

The final receipt is restricted to `README.md`, this evidence record and
`Docs/superpowers/plans/2026-10-24-stage8-skills-environment.md`. The manifest
for App, Tests, Config, Resources, `.github` and `project.yml` matches tested
source `def1fcd` with SHA256
`087A4140F204E4B9A9EAA18B9F89333E03E87F1A664351F20FD08E8716FAA527`.
The unchanged normal workflow, profiles, budgets and assertions were preserved.
All three earlier full REDs and their complete SHA-matched archives remain
saved with the final GREEN evidence. One continuous whole-branch reviewer
checked the material corrections and bounded follow-ups; no new review seat
or deferred review Minor remains.

Implementation PR #43 and Blueprint PR #8 remain draft/open/unmerged, stacked
on their Stage 7 branches. Physical-device UI, Keychain/data-protection behavior
and user experience remain separate acceptance. No Stage 9 work, merge or
package delivery is included.

# Stage 6 completion - native implementation gate closed; device acceptance open

Authority: Blueprint `fffca086f4451a7bd0988959058ddcfe5eb6c13d`, development plan Stage6,
Tool Runtime sections4–7/9/12/14/16 and security permissions/data egress.
Implementation plan: [2026-10-23-stage6-completion.md](../Docs/superpowers/plans/2026-10-23-stage6-completion.md).
Owner authorized allStage6 and explicitly approved the necessary Settings→Agent→Callable Tools,
conversation approval scope, exact file/provider disclosure and separate OS-consent interaction.
Existing Sidebar/Composer/menu geometry, gestures, animation, assets and signing remain frozen.

## Final normal native gate

[Normal CI 39913184297](https://github.com/54zhien/Zen-Agent/actions/runs/39913184297)
completed **SUCCESS** on source `c4b5e987821b73945143ae72fcea477c0682160a`, tree
`9ff78a1cde6f6cbfe6740467cc945a5ecf97b06e`. Repo hygiene, XcodeGen generation,
App build and both required native axes passed without Stage 6 diagnostic selectors.

| Layer | Actual result |
|---|---|
| Swift Testing | 1,224 tests / 187 suites, 129.362s, zero issues |
| XCTest unit | 20 passed, 2.964s |
| Phone UI | 85 passed; one Pad-only platform skip; 2,698.589s |
| Stage 6 UI subset in that full run | all six passed, 256.763s |
| Native Pad | one passed, no skip, 108.941s |
| Host integrity | one actual Swift Testing start; no duplicate XCTest case events or restart acceptance |

Phone job120280689866 raw-log SHA256:
`3fe938202f491f48133e8c1b9591939812cac522ee5d2fe29b176c00f499906c`.
Pad job120280689923 raw-log SHA256:
`e49a0897c9ce29d59f18e5294f220dbfdb65f80f6bce4a4f985eadc54b991b57`.
GitHub's native artifact receipt: id12486777977, 385,570,851 bytes, reported digest
`sha256:abfeb66258b36212b6012ae07a5e117af496877f32c8d02bab80fe9b2ab98172`.

The final acceptance receipt is restricted to `README.md`, this gate and
`Docs/superpowers/plans/2026-10-23-stage6-completion.md`. Complete changed-path
allowlisting and a byte-identical App/Tests/Resources/Config/project/workflow check
bind the final branch to the tested source; these Markdown files are not build or
test inputs. The definitive merge identity/tree and post-merge CI are recorded on
[PR #41](https://github.com/54zhien/Zen-Agent/pull/41); post-merge results are separate
from this successful pre-merge gate.

Physical-device acceptance remains open. No Stage 7-10 or IPA/signing work is included.
The accepted Sidebar/Composer geometry, gestures, animation, typography and assets
were preserved. Only the owner-approved Tools Settings, approval scope/disclosure
and independent system-consent additions were introduced. Approval refresh uses
an event revision to avoid losing a routed wait or applying a stale read.

The candidate-by-candidate execution notes below preserve failures, cancellations
and intermediate pending observations. This final normal gate supersedes their
pending status; none of those partial runs is substituted for aggregate acceptance.

## Integration baseline

PR39 merged at `e2e31972cd894da96ef110c8a2ebc3078cfd7d61` / tree
`3cb0433cc2576a2f0539b86900aae32b6a4fbd09`, identical to its tested source.
Owner explicitly accepted carrying the intermittent first-edge Sidebar failure in
[issue40](https://github.com/54zhien/Zen-Agent/issues/40); original full run39807102425 remains RED.
Normal post-merge [39888595366](https://github.com/54zhien/Zen-Agent/actions/runs/39888595366)
subsequently passed:1162Swift/181suites120.198s;20XCTest; Phone79UIpasses plus1Pad-onlyskip;
Pad1/1 in117.645s. This is baseline evidence, not current Stage6 acceptance or proof of Sidebar repair.
Original UI checkout/PR37 remain parked and untouched.

## Stage matrix

| Slice | Implementation | Native evidence | Device |
|---|---|---|---|
| S6-01 Policy kernel | on main | prior gate | separate |
| S6-02 frozen actions/intents | on main | prior gate | separate |
| S6-03 persistent Policy/grants | on main | prior gate | separate |
| S6-04a original Runtime authority | on main | normal post-merge full GREEN above | pending |
| S6-04b OS consent/conversation scope | PR41 | full normal gate above | pending; injected driver is not device acceptance |
| S6-05 Files.read/egress/result guard | PR41 | full normal gate above | pending |
| S6-06 create/modify/delete | PR41, shared reservation and immutable receipts | full normal gate above | pending |
| S6-07 callable tool Settings/exposure | PR41, real registry and approved UI | full normal gate; all six tool UI cases passed | pending |
| Aggregate Stage6 | implementation complete in PR41 | normal full native gate PASSED | physical acceptance OPEN |

## Evidence and failures retained

- S6-04b actual RED39adeaf/run39889595076:11tests/17issues, real App/test build; Tool-approval-first
  and already-authorized dispatch controls passed. `.notDetermined`/denied/restricted/unavailable
  entered executor and explicit conversation scope was unavailable before implementation.
- S6-04b GREEN795676c/run39892484142/job120215288235:1179Swift/182suites119.440s and20XCTest;
  App/XcodeGen passed. Diagnostic unit-only profile deliberately skips Pad and selects no PhoneUI.
  Rawlog SHA256854b0aa5f2127803f105c7535f2117d9ab8bbd5ffd937e4592cb88f4dbd254f0;
  artifact12475628515,83925028bytes,digestca0e3a78d60b40a915315dcf6e3f1877ce3ecc01381f783c4e12a52a6f97343f.
- S6-05 actual REDad91bb7/run39892692496:1188Swift/184suites101.648s/15issues,20XCTest passed.
  New Files preparation/result guard contracts failed; all legacy/system-consent suites passed.
  Rawlog SHA256ab9c5261db15d12499deeaab1e6b8fa62a03c40a1cc96707cb97ae2973f84cf1.
- Extended read continuation REDbd15d7e/run39893209475:1189Swift/184suites227.261s/16issues.
- Read implementation8dab375/run39894019956:1192Swift/184suites135.749s failed only old-schema
  fixture seeding v17 fields into v15. Actual managed read/result guard and real Provider continuation
  passed. Fix seeds old three-column result rows and checks upgraded defaults. Isolated candidate346f875/
  run39895412525 contains only that fixture fix over8dab375; it is not current feature-head acceptance.
- Follow-up generic `token` field gap observed RED→GREEN by compiling/running the actual pure
  Foundation guard with WindowsSwift6.4.1; escaped known credential control passed. This does not build
  UIKit or replace Apple CI. Native test added; exact read candidatea736d27/run39896048892 pending.
- Initial write contract02b5c89/run39894373463 is a fixture compile failure (missing required checkpoint
  timestamp), not behavior RED. Corrected0760144/run39895723506 includes write/Settings contracts.
  Settings0439077/run39895607623 inherited that known fixture and was cancelled early by us.
  Earlier ca429d5/run39889227112 was likewise cancelled for a known test-helper compile defect.

## Backend closure and follow-up evidence

- Whole backend f8516bb42eec521f881a7189f49af2261efd4cae / [39900808186](https://github.com/54zhien/Zen-Agent/actions/runs/39900808186) / job120241751603 passed:1214Swift in186suites155.819s,20XCTest, XcodeGen/App build. Includes actual managed bytes, version CAS, warm/pendingSend/twoPane deletion protection, before-publication and result-commit cancellation, concurrent modify/delete, minimal uncertain receipts, query-only recovery, consent races, persisted Settings and revocation causes. Unit-only diagnostic; no PhoneUI, Pad deliberately skipped. RawlogSHA256C0FE95C62040D053D05A564534CF482559BADF9369889D0A4EC703C7F362409C.
- Actual managed-write REDf8f999f/[39896540449](https://github.com/54zhien/Zen-Agent/actions/runs/39896540449):1203Swift/186suites146.826s/10issues. b98127a/39899183274 passed writes/consent while the then-empty Settings model remained RED.
- Consent request ownership RED907f416/39897008021 and actual executor-denial RED16aa8fe/39897582158 were fixed with a process-wide owner, same-process request preservation and stable typed denial. Full backend GREEN above includes these regressions.
- Native Tool Settings entry REDd9f1c4d/[39896795718](https://github.com/54zhien/Zen-Agent/actions/runs/39896795718):1UItest/1failure51.905s, missing settings-tools after reaching the existing Agent page; App/test build passed.
- Exposure/lifetime RED320356f/[39901462556](https://github.com/54zhien/Zen-Agent/actions/runs/39901462556):1216Swift/187suites111.098s/3issues plus20XCTest passed. Exactly unsupported-model snapshot/request exposure and strong presentation-owner retention failed; supported-model control and all other tests passed. Fix4876b20 uses model capability and frozen snapshot, plus a weak reference to the actual SessionStore. Native follow-up pending.
- Old fixture-only compile failures and early cancellations remain failures, not behavioral evidence:346f875/39895412525 captured a mutable record in a Sendable closure; a736d27/39896048892 and0760144/39895723506 inherited known fixture errors and were cancelled. Final read255ebbf/[39896566572](https://github.com/54zhien/Zen-Agent/actions/runs/39896566572) passed1193Swift/184suites147.091s plus20XCTest.

## Integration and remaining acceptance

- The single fresh whole-branch review and its one corrective RED-to-GREEN pass are complete.
- The normal workflow is restored; full Phone and Pad gates passed at the source above.
- The owner authorized direct integration after passing. PR41 holds the definitive merge/tree
  receipt and separate post-merge CI; the original UI checkout and PR37 remain untouched.
- Device permission behavior, narrow 375-point rendering and reduced-motion visual acceptance
  were not separately claimed by the new-page QA. Inherited Sidebar issue40 remains open.
- Later-round cold continuation safely stops when its committed transcript is incomplete;
  original completed file effects are still confirmed without re-execution.


## Final review and current limits

The single fresh whole-branch review at1694a5b found2Important,0Critical,0Minor:
semantic JSON credential redaction and preserving committed file effects when result publication
fails. The corrective pass is open; neither review findings nor aggregate Stage6 are closed yet.
Original4368cf3/[39906018910](https://github.com/54zhien/Zen-Agent/actions/runs/39906018910)
failed test compilation because SwiftTesting cannot recursively expand nested `#require`;
corrected137d4a7/[39907003747](https://github.com/54zhien/Zen-Agent/actions/runs/39907003747)
and no-proof control163f910/[39907096691](https://github.com/54zhien/Zen-Agent/actions/runs/39907096691)
are pending. Compile failure is not behavioral RED. The semantic guard passed the actual
Windows Foundation executable regression after6observed pre-fix issues; Apple integration remains required.

- Backend64eab58/[39904355414](https://github.com/54zhien/Zen-Agent/actions/runs/39904355414)
  passed1217Swift/187suites137.702s plus20XCTest22.995s, generation/App build.
- Exposure/lifetime4876b20/[39902575800](https://github.com/54zhien/Zen-Agent/actions/runs/39902575800)
  passed1216Swift/187suites140.973s plus20XCTest; production model capability and weak SessionStore ownership verified.
- Formal empty-registry Settings entry616dba7/[39902024495](https://github.com/54zhien/Zen-Agent/actions/runs/39902024495)
  passed1UItest37.935s and retains the original draft.
- Actual tool UI493f8bd/[39904143921](https://github.com/54zhien/Zen-Agent/actions/runs/39904143921)
  failed6assertions across6tests247.743s. Native hierarchy showed3cards whose root identifier was
  overwritten by the existing Pane identifier;1system card was genuinely absent despite a routed waiting event.
  ca20b9f uses event revision refresh and stale-read cancellation without changing geometry or gestures;
  tests locate surviving child elements. Landscape QA follows the existing navigation-reset behavior.
  Follow-up[39906491974](https://github.com/54zhien/Zen-Agent/actions/runs/39906491974) is pending.

Inherited cold continuation reconstructs only the first protocol round. Missing later-round committed
transcript settles the Run as unrecoverable instead of silently omitting history. Recovery still queries
original immutable file receipts before continuation reconstruction; it never replays an uncertain write.
This limit is separate from confirming the truth of an already committed file operation.
No real Calendar/microphone/location executor or MCP is exposed; physical OS behavior remains separate
acceptance. Future all-local-data erase must explicitly own the minimal uncertain receipt/tombstone cleanup;
there is no such erase API in this checkout.

## Corrective backend gate

Native6c21c36/[39909441739](https://github.com/54zhien/Zen-Agent/actions/runs/39909441739)/job120268796370
passed1224Swift/187suites162.643s plus20XCTest0.935s, XcodeGen/App build. The single review's
2Important findings now have actual RED->GREEN evidence: semantic JSON redaction and real
Files->durable result->Provider continuation; committed file effect publication/cold confirmation with
both colliding known credential and unavailable credential backend; unproven external effects remain
indeterminate with no invented terminal result. No second reviewer was used. Raw log SHA256
`0a38be8072c26c8e5b23ecbe1e9211810d024439a572324fafcf7ee2df62f70c`.

Corrected137d4a7/[39907003747](https://github.com/54zhien/Zen-Agent/actions/runs/39907003747)
actually reproduced11publication/recovery issues while I1 native controls passed. Additional no-proof
control163f910/[39907872092](https://github.com/54zhien/Zen-Agent/actions/runs/39907872092)
reproduced13issues in1224Swift/187suites131.433s;20XCTest passed. This is behavioral RED, distinct
from the earlier fixture compile failure. Cancelled39907096691 was a same-ref concurrency mistake,
not a verdict; its replacement ran the identical source on an independent ref. UI39906491974
inherited the nested-macro compile defect and never executed UI. Those runs remain in history.

The restored normal workflow is byte-identical to the integration baseline: no Stage6 diagnostic
inputs or skipped axes,85min Phone ceiling preserved. Exact source756a9f9/tree
`4708c01e1d9d3504fc4a7e63f60448506d822a58` runs the full gate in
[39909994653](https://github.com/54zhien/Zen-Agent/actions/runs/39909994653).
Its Pad job120270561662 passed1/1 native test102.638s with no skip; Phone is still running.
Pad log SHA256`255a13dde0faa905650057e2261430046a65218f201d93a404113bc62aa857aa`.
This does not close inherited intermittent Sidebar issue40.

## UI adaptation and rendered QA

5a08263/[39909647686](https://github.com/54zhien/Zen-Agent/actions/runs/39909647686)
passed the five real tool flows; the remaining largest-text landscape failure came from native AX
reporting Agent hittable while its row center was underneath the navigation bar after an inertial
scroll. c4b5e98 changes only the test's scrolling/tap bounds, requiring the whole target below the
existing toolbar; production geometry and interaction remain unchanged.
The source-identical workflow-only diagnostic86e0e524/
[39911886203](https://github.com/54zhien/Zen-Agent/actions/runs/39911886203)
passed the exact largest Dynamic Type dark portrait/landscape test1/1 in82.720s.
Application-region landscape capture had an incorrect crop/orientation, so it was not accepted as
rendering evidence. Independent40e2f087/
[39913521291](https://github.com/54zhien/Zen-Agent/actions/runs/39913521291)
changed only the screenshot expression and diagnostic workflow, preserved all assertions/gestures
and App code, passed1/1 in84.315s and exported valid full-screen portrait/landscape pixels.
Both were inspected: navigation and policy control remain visible and native Form content scrolls.
No product UI change was needed for the capture or AX issues.

Current normal full source is c4b5e987821b73945143ae72fcea477c0682160a/tree
`9ff78a1cde6f6cbfe6740467cc945a5ecf97b06e` in
[39913184297](https://github.com/54zhien/Zen-Agent/actions/runs/39913184297).
Pad1/1 passed108.941s; Phone remains in progress. Earlier normal39909994653 was cancelled by us
once the known largest-test failure was identified, preserving its Pad success and Phone cancellation;
it is not aggregate acceptance. Its source has not been rerun unchanged to hide the failure.

## Final review disposition

One fresh reviewer at frozen1694a5b found two Important, no Critical and no Minor findings.
Both important findings are fixed with actual failing execution followed by passing checks:
semantic JSON credential redaction (Windows Foundation RED, native integration GREEN), and
committed effect truth across unavailable result publication (native RED->GREEN, including
original-call cold confirmation and no-proof indeterminate control). The complete normal native
gate above covers the final implementation and all UI assertions. No second review was used.

The reviewer-set-aside items were ruled explicitly: physical OS behavior is device acceptance;
Stage7-10/MCP and real system-capability tools remain outside scope; issue40 remains inherited;
minimal uncertain receipts follow the existing tombstone exception and require explicit ownership
when a future all-local-data erase API is built; inherited first-round-only cold transcript rebuilding
fails safely instead of dropping protocol history. The execution ledger retains each ruling and cost.

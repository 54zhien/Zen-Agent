# Stage 6 completion gate — in progress

Authority: Blueprint `fffca086f4451a7bd0988959058ddcfe5eb6c13d`, development plan Stage6,
Tool Runtime sections4–7/9/12/14/16 and security permissions/data egress.
Implementation plan: [2026-10-23-stage6-completion.md](../Docs/superpowers/plans/2026-10-23-stage6-completion.md).
Owner authorized allStage6 and explicitly approved the necessary Settings→Agent→Callable Tools,
conversation approval scope, exact file/provider disclosure and separate OS-consent interaction.
Existing Sidebar/Composer/menu geometry, gestures, animation, assets and signing remain frozen.

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
| S6-04b OS consent/conversation scope | branch implementation |1179Swift+20XCTest GREEN at795676c | pending; injectable driver is not OS-device acceptance |
| S6-05 Files.read/egress/result guard | branch implementation |1193Swift+20XCTest GREEN at255ebbf; whole backend GREEN below | pending |
| S6-06 create/modify/delete | branch implementation, shared reservation and immutable recovery receipts | whole backend GREEN below | pending |
| S6-07 callable tool Settings/exposure | backend and approved UI/real registry wired | backend GREEN; UI/exposure follow-up pending | pending |
| Aggregate Stage6 | OPEN | normal final exact-head Phone/Pad gate pending | OPEN |

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

## Remaining final gates

- Finish native UI/exposure verification and action-version reconfirmation disclosure.
- One fresh-context whole-branch review and required corrective RED→GREEN checks.
- Restore normal workflow: diagnostic selectors, intentionally skipped axes and in-progress runs
  never stand in for final acceptance. Verify final exact-source XcodeGen/App/unit/Phone/Pad results.
- Record merge tree equality and post-merge CI separately. No Stage7–10 or IPA/signing work.

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

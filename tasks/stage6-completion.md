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
| S6-05 Files.read/egress/result guard | branch implementation | final scoped candidate pending | pending |
| S6-06 create/modify/delete | contracts only; no production writes | corrected behavioral RED pending | pending |
| S6-07 callable tool Settings/exposure | fail-closed model contract only; no production exposure | behavioral RED pending | pending |
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

## Remaining final gates

- Finish managed mutation/receipt recovery and shared Session reservation integration.
- Finish Settings policy/scope/revocation facts and expose only real production executors.
- One fresh-context whole-branch review and required corrective RED→GREEN checks.
- Restore normal workflow: diagnostic selectors, intentionally skipped axes and in-progress runs
  never stand in for final acceptance. Verify final exact-source XcodeGen/App/unit/Phone/Pad results.
- Record merge tree equality and post-merge CI separately. No Stage7–10 or IPA/signing work.

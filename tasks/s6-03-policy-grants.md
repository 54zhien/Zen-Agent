# S6-03 Policy / grant persistence

## Scope and authority

Owner authorized Stage6 continuation on 2026-10-22, with finalized UI frozen and Sidebar diagnostics parked/restored. Base main: `f12cb87be247cd3cd5cf54743bdeea68f92a8e50`; its full native CI [38847153473](https://github.com/54zhien/Zen-Agent/actions/runs/38847153473) passed. UI PR #37 remains draft/unmerged; this work does not accept or merge its RED UI candidate.

Plan: [S6-03 implementation](../Docs/superpowers/plans/2026-10-22-s6-03-policy-grants.md), following [approved Stage6 roadmap section7](../Docs/superpowers/plans/2026-10-07-stage6-policy-foundation.md). Blueprint `fffca086f4451a7bd0988959058ddcfe5eb6c13d`; Tool Runtime blob `9d961dc500d8b39bf1623e568becf347cf5239c7` and security blob `79d8b5355466d7fad47c673416e7c4c5c0105b12` are unchanged from the S6-02 approved specification.

Only Persistence implementation, its two new test files and own plan/record differ from main. No UI, Runtime, Config, Resources, project.yml, dependencies, signing or IPA change. The temporary RED-only workflow selector is removed from the final candidate. Windows checks are not an Apple SDK build.

## Resulting contract

- v14 stores global action policy separately from scoped immutable grant issuance. Reuse the existing domain values and sole evaluator; no second authorization engine or executable payload.
- Policy identity is byte-exact tool/action; revision mismatch is preserved for rejection. Tightening/revision changes advance an Int64-backed nondecreasing revocation epoch and revoke active grants atomically. Widening cannot revive them.
- Successful first issuance anchors an implicit default ask/revision/epoch0 policy in the same transaction. Otherwise the first explicit revision update could miss old grants. Rejected issuance creates no policy row; insert failure rolls the transaction back.
- Issuance validates expected policy, live original root Parent Run/Conversation, undispatched original call, known frozen action/revision, exact file version/provider endpoint and approval witness. IDs cannot overwrite/revive prior issuance. Subject-list recovery retains issuance IDs for explicit revocation.
- Child-origin issuance is refused for both kinds and all submitted subjects, matching the existing Runtime approval boundary. Recursive ancestor support belongs to the later Subagent stage. Run-subject root Parent grants remain supported.
- Original call terminal/indeterminate/deletion consumes once grants. Run terminal/deletion consumes its once grants and revokes Run-subject grants. Conversation hide/delete revokes its grants; Undo cannot restore authority. Parent-conversation grants survive an individual originating Run/call ending or being pruned.
- Strict malformed/unknown scope decoding fails closed. Opaque intent-binding derivation remains a trusted Runtime caller contract to prove in S6-04, not an authorization bypass or an implemented dispatch path.

## Native evidence and preserved failures

| Source | Native run | Actual result |
|---|---|---|
| `b74ea125` | [39752552317](https://github.com/54zhien/Zen-Agent/actions/runs/39752552317) | Hygiene, XcodeGen and app build passed; test compile failed in 7 throwing `#require` macros. No behavioral RED. Fixed explicit inner `try`. |
| `1611e65` | [39754034808](https://github.com/54zhien/Zen-Agent/actions/runs/39754034808) | Incomplete cancellation, not RED/GREEN. Main20 XCTest passed, Swift run started but no S6-03 case starts/completed summary. Pad1/1 passed. Cancellation was premature; Pad timing did not prove main unit completion. |
| `a436d1c` | [39756206466](https://github.com/54zhien/Zen-Agent/actions/runs/39756206466) | Actual contract RED:13 tests/2 suites,20 assertion issues in0.768s. Native generation/app/test build passed; negative controls including Child-origin rejection passed. Disclosed focused profile; Pad skipped, no Phone UI. |
| `e83b113` | [39758615847](https://github.com/54zhien/Zen-Agent/actions/runs/39758615847) | Superseded implementation cancelled because fresh review found a real P2. Hygiene passed; native jobs cancelled before completed test summaries. Not a timing-based assertion of unit completion or a full pass. |
| `1e42937` | [39759333708](https://github.com/54zhien/Zen-Agent/actions/runs/39759333708) | Actual review regression RED:14 tests/2 suites, exactly2 issues in0.739s, only `firstRevisionUpdateRevokesGrantsIssuedUnderImplicitDefault`. Epoch stayed0 and grant was not revoked; original13 functions passed. Native app/test build passed. Focused profile/Pad skip disclosed. |

Both focused RED runs completed; no timing cancellation. Final source restores the normal workflow, including full Phone unit/UI and independent Pad axis tests. The final source SHA/run/job/artifact and integration result are published in the S6-03 PR receipt so recording a run ID does not mutate the verified source tree. Neither focused RED nor any cancelled run constitutes the final full gate.

Raw logs retained outside Git in the task artifact directory. SHA256:

- b74 build: `34c69bde8bdfe21e8a0e8992b481ad853ee026265941bc11e6ca302cc55acc84`; Pad: `7d3d442d5274633dfce64ed2217547692aa5cea3a02cb3ed45e5ad2c2b10a78f`.
- 161 cancelled main: `18af39e5658aeb4952439ed6fae4ff4a33451683f01f20960cabd3ad76fc59d6`; Pad: `d892f98806bd2fae276e79861ac5c322c17afea90b7fc67b0736c80168de5a44`.
- a436 actual RED: `f1dc2066411f2224d2144c844ca86a7d5db6d345ae538a8f3998596f21a5db1d`; artifact12416642314, digest `4688af2fd1b916313f3816ad8cbce00d350ecf68b620261d0d6495b2a7211dbe`,73685822bytes. Artifact download retried after network EOF only; tests were not rerun.
- e83 cancelled main: `61257df14f0b102d462aebae364f137963b9e54fbf2b9fee54831c2255bd7933`; Pad: `6be9462fe748a0f49fab61c2566ebd2efe450565e1f5c38536ba863f1a3dae6d`.
- 1e42937 review RED: `b2ed8a25b5c1280cfd708f09424359cd3b66e78ad10d71bbd7f54c4c47c98b92`.

## Review and validation boundary

Fresh whole-slice review of e83 found one P2: implicit defaults did not anchor the issuance revision, so a first explicit revision update could miss revocation. One test-first fix pass reproduced it natively, then anchored the validated policy immediately before grant insert in the existing transaction. The same reviewer inspected the actual narrow fix and found no directly related Important/Critical issue. Review is not a build result.

Windows Swift frontend parsing, all migration SQL/lifecycle smoke controls, project/workflow YAML and paths, workflow Bash syntax and12 existing Python CI-script tests pass. These do not substitute for the final native gate recorded in the PR.

S6-03 does not wire Runtime approval/pre-dispatch/OS consent, Files capabilities or Settings. These remain S6-04 through S6-07. No Stage6 aggregate closure or physical-device acceptance is claimed. Any change to accepted UI/interaction must stop for an impact report before implementation.

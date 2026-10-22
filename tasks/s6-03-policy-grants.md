# S6-03 Policy / grant persistence

Owner authorized Stage6 continuation on2026-10-22, with finalized UI frozen and Sidebar diagnostics parked. Base main f12cb87, prior full native CI38847153473 success. This is storage only; runtime/pre-dispatch/OS consent integration remains S6-04. Existing UI PR37 is draft/unmerged, no GREEN claim for that branch.

Plan: [2026-10-22-s6-03-policy-grants.md](../Docs/superpowers/plans/2026-10-22-s6-03-policy-grants.md). Blueprint fffca086f4451a7bd0988959058ddcfe5eb6c13d. Windows static checks do not constitute a build. Native RED/GREEN evidence pending. No UI, package/config/workflow/signing or IPA change.

Initial RED candidate:12 native contract functions (4 Policy,8 Grant), unused compile-safe storage signatures only. Static Swift parse, project/workflow YAML, declared source paths, workflow Bash syntax and12 Python script tests passed. Original UI/config/project/workflow diff is empty. Native behavioral result pending.


Ruling after source/security review: match the existing ConversationRuntime approval boundary: grant issuance only accepts an original root Parent Run (kind parent and parentRunID nil), for both grant kinds and both subjects. Child-origin grants stay unavailable until the later Subagent stage implements ancestor validity/expiry. Existing ToolApprovalUITests already excludes Child calls. No recursive child lifecycle scaffolding in S6-03. Added parameterized negative test covers actual Child origin attempting its own Run, Parent Run and Parent Conversation subjects; storage never trusts the display subject alone. These extra negative controls are prepared before implementation, outside the already-running12-function RED source.


Pre-RED compilation failure: b74ea125 / run39752552317. XcodeGen, hygiene and application build passed; both native jobs failed while expanding7new #require expressions around throwing store calls. Outer try does not mark the macro argument's call; add explicit inner try. No UI test starts and no behavioral RED. Preserve failed run; source review/Windows parse had not detected this SDK macro expansion error. Next source includes the Child-origin negative controls and this test-only compile correction, with production signatures still unused stubs.

# S6-03 Policy / grant persistence

Owner authorized Stage6 continuation on2026-10-22, with finalized UI frozen and Sidebar diagnostics parked. Base main f12cb87, prior full native CI38847153473 success. This is storage only; runtime/pre-dispatch/OS consent integration remains S6-04. Existing UI PR37 is draft/unmerged, no GREEN claim for that branch.

Plan: [2026-10-22-s6-03-policy-grants.md](../Docs/superpowers/plans/2026-10-22-s6-03-policy-grants.md). Blueprint fffca086f4451a7bd0988959058ddcfe5eb6c13d. Windows static checks do not constitute a build. Native RED/GREEN evidence pending. No UI, package/config/workflow/signing or IPA change.

Initial RED candidate:12 native contract functions (4 Policy,8 Grant), unused compile-safe storage signatures only. Static Swift parse, project/workflow YAML, declared source paths, workflow Bash syntax and12 Python script tests passed. Original UI/config/project/workflow diff is empty. Native behavioral result pending.


Ruling after source/security review: match the existing ConversationRuntime approval boundary: grant issuance only accepts an original root Parent Run (kind parent and parentRunID nil), for both grant kinds and both subjects. Child-origin grants stay unavailable until the later Subagent stage implements ancestor validity/expiry. Existing ToolApprovalUITests already excludes Child calls. No recursive child lifecycle scaffolding in S6-03. Added parameterized negative test covers actual Child origin attempting its own Run, Parent Run and Parent Conversation subjects; storage never trusts the display subject alone. These extra negative controls are prepared before implementation, outside the already-running12-function RED source.


Pre-RED compilation failure: b74ea125 / run39752552317. XcodeGen, hygiene and application build passed; both native jobs failed while expanding7new #require expressions around throwing store calls. Outer try does not mark the macro argument's call; add explicit inner try. No UI test starts and no behavioral RED. Preserve failed run; source review/Windows parse had not detected this SDK macro expansion error. Next source includes the Child-origin negative controls and this test-only compile correction, with production signatures still unused stubs.


Correction to cancellation inference: source1611e65/run39754034808 was cancelled too early to establish RED. Main's20XCTest passed, then Swift Testing started09:28:26; the captured log has zero S6-03 case starts/issues and no completed Swift summary, zero Phone UI starts. Pad1/1 did pass. Main spent substantially longer compiling than Pad; Pad timing is not evidence that main had finished units. Preserve this incomplete run, never call it behavioral RED or full GREEN. Raw logs retained.

Ruling: add a temporary manual s6_contract_red selector to the existing workflow, running only the two new native suites and omitting the independent Pad job only for this RED profile. This is a source/test-selection change justified by the missing target execution, not an unchanged rerun. No production behavior changes; stubs remain. Let this targeted job complete, no timing-based cancellation. Remove every workflow/profile change byte-for-byte to1611e65 before implementation's clean full CI. The prior full-suite plan is superseded only for RED evidence acquisition; final full gate is unchanged.


Actual behavioral RED: sourcea436d1c / run39756206466 / job119748805089 completed expected failure. XcodeGen/application build/native test compilation passed. Exactly13 Swift tests in2new suites executed and completed in0.768s with20 assertion issues (9 Grant,11 Policy); negative controls including Child-origin rejection passed. One actual Swift run, no Phone UI starts, Pad intentionally skipped in this disclosed RED-only profile. The earlier cancelled1611 run is not RED. Raw log SHA256 f1dc2066411f2224d2144c844ca86a7d5db6d345ae538a8f3998596f21a5db1d. Workflow already locally restored byte-for-byte to1611e65/main. Implementation may now begin; final normal full native gate still required.


Implementation ruling: grant subject-list reads retain named issuance IDs alongside the existing ToolScopedGrant values, so recovery can revoke the original row without deriving an ID from displayed scope. This is a storage address, not a second Policy model; there are no existing production callers to migrate. The reopen test verifies the ID/value projection. Added both call-terminal-first and run-terminal-first variants to the existing lifecycle contract before implementation verification. No per-variant RED is claimed beyond the observed13-function/20issue source.

v14 implementation prepared: separate Policy/Grant tables and lifecycle triggers; original root Parent Run validated in the issuing transaction; immutable scope/version/endpoint and expected Policy floor; no upsert/revival; strict scope decoding. Workflow restored to main, no temporary selector retained. UI/Runtime/Config/Resources/project.yml unchanged. Static/native final verification pending.


Implementation static verification: Swift frontend parsing of all7changed/new Swift files passed; all8raw migration SQL statements parse and original call/run/Conversation lifecycle invalidation controls pass against SQLite on Windows. Project/workflow YAML, declared source paths, workflow Bash syntax and12 existing Python CI-script tests pass. Workflow is byte-identical to main. These checks do not substitute for the upcoming SDK compile/full native gate. Fresh whole-slice read-only review is running. Only Persistence implementation and own tests/docs differ from main; UI, Runtime, Config, Resources, project/dependencies/signing untouched.

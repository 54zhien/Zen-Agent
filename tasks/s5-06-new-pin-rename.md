# S5-06 New / Pin / Rename — execution record

## Authority and delivery boundary

Blueprint `596a84d4b58769e3e7b838be95edcb43f9e0ec82`, App Space sections 5/6/19, message/data title/activity rules, Provider section6 creation-time binding, CONTEXT.
User requested strict Stage5 development and S5-06 continuation. All physical acceptance is deferred by the owner until Stage5 development ends.
Production desktop remains clean main `eec3eb3`; worktree branch `codex/s5-new-pin-rename` starts at tested PR22 `bca95d9`.
[PR23](https://github.com/54zhien/Zen-Agent/pull/23) targets `codex/s5-card-browse-snap`; PR22 remains unmerged.
No merge authorization is inferred. New/Pin/Rename only; S5-07 and other later slices remain outside this task.

## Native RED

Tests-only source `0f387a05b04eabed76372261f838097bd770342e`, tree `edee326131a8091fa2ec40e7b39167d204e1903a`.
[Push CI36580154583](https://github.com/54zhien/Zen-Agent/actions/runs/36580154583), job `109445979443`:
generation/App/test compilation passed,759 Swift Testing /112 suites62.852s and20 XCTest passed.
18 UI332.775s:2 intended failures (missing distinct rightmost New, missing Current ellipsis), plus one unchanged distant Browse failure reaching history4.
No production source was changed. The old failure is retained with unknown cause; it is not labelled flaky and original assertions are not relaxed.
PR CI36580209030 was superseded/cancelled; its cancelled logs were unavailable. No RED/GREEN claim for that run.

## Runnable new API RED scaffolding

Source `227e95e5c5d2250593d6c39d1083c391fe4c0aa5`, tree `37f7c1878c0c2efd454c01676321a0fe9710c3be`.
New signatures are inert: metadata edits/configure no-op, creation explicitly throws, marker false; no product behavior.
This recorded compatibility exception follows actual existing-API native RED. Missing symbols or compilation failures are not behavioral RED.
[Push CI36582275649](https://github.com/54zhien/Zen-Agent/actions/runs/36582275649), job `109453329441`, completed:
XcodeGen/App/test compile passed;772 Swift Testing /116 suites84.056s reported37 issues;20 XCTest passed.
18 UI416.395s had only the2 intended New/menu failures; original16 UI, including distant browsing, passed without product changes or relaxed assertions.
There was one actual Swift start and no actual host restart. The failed native first push observation remains unexplained, not claimed fixed.
Three Swift issues belonged to the subsequently rejected empty-open mutable-global assumption; they are not feature RED evidence.
The remaining34 cover inert metadata/manual marker/creation/window/selected-owner behavior. PR36582283469 subsequently completed with failure on the same source; this receipt's detailed RED evidence is the push job above.

## Binding-policy RED correction

Before feature implementation, Provider section6 rejected the mutable-global empty-open assumption.
The next tests-only revision adds creation-time copied binding, changed-global cold reopen, explicit unconfigured state,
exactly-once explicit Configure initialization and configured-empty LRU controls. API additions remain inert.
Old correct assertions remain; the incorrect newly drafted global-fallback case is replaced with the actual creation-time binding requirement.
Source `e5ed0e27068d4a1a1b94c4f6c3c496241210c36e`, tree `de33989a76c841e11a0dd22060c25965fd47b2bf`.
[Push CI36585196927](https://github.com/54zhien/Zen-Agent/actions/runs/36585196927), job `109463620270`, completed with actual behavioral RED:
generation/App/test compile passed;778 Swift Testing/116 suites129.411s,41 intended issues
(10 shell ownership/binding,3 creation,12 New Browse,1 migration marker,15 metadata).
20 XCTest passed;18 UI475.633s had only the2 intended New/menu failures; original16 UI passed.
One actual Swift start, no host restart. An early log download before job finalization returned BlobNotFound; final complete logs were read successfully.
PR36585204137 also completed with failure on the same corrected tests-only source; detailed counts above come from the complete push logs.

## First implementation candidate

After matching behavioral RED, implemented metadata transactions and bounded distinct New; after corrected binding RED,
implemented atomic empty creation/Soul/initial binding, explicit null-binding initialization, retry identity, cold reconstruction and weak LRU.
Native menu captures the selected ID and suspends motion; dismissal restores logical input availability while delegates check actual UIKit overlays.
New uses the existing two-segment Surface/Preview handoff and Resting Composer. Metadata errors belong only to their selected ID.
The old newest-card accessibility assertion is intentionally updated for the authorized new rightmost entry;
its older/newer/session/request controls remain and now exercise native New/back with no metadata menu on New.
Native menu test additionally checks Cancel and post-dismissal swipe. Existing first-user-text summary fallback is reused.
Migrations.swift line endings are normalized to LF for the default whitespace gate; old migration SQL behavior is unchanged.
No full GREEN or completion claim before candidate CI.
Published candidate `9dcb508bbc476cfa4612f13366cf8a15c2e04c5c`, source tree `7ec32b63132a2fc546613edf6cf1e345cdf5c73d`.
Actual PR merge `361ccf4cd382a9b89775d1556b06bc64fe0fa4f3` has the identical tree.
[Push CI36588413830](https://github.com/54zhien/Zen-Agent/actions/runs/36588413830), job `109474906354`, completed successfully:
XcodeGen/App build/test passed;778 Swift Testing/116 suites81.133s,20 XCTest,18 UI460.719s,0 failures.
The actual command was `xcodebuild test -project ZenAgent.xcodeproj -scheme ZenAgent -configuration Debug -destination id=<CI simulator> -resultBundlePath <CI result bundle>`.
One actual Swift start; no actual host restart; command guard passed, failed-only host diagnostics/artifacts skipped.
Both native metadata UI tests passed, including Cancel and post-dismissal navigation; all original16 UI controls passed.
[Guard self-test36588420776](https://github.com/54zhien/Zen-Agent/actions/runs/36588420776) passed.
[PR CI36588420757](https://github.com/54zhien/Zen-Agent/actions/runs/36588420757), job `109474894296`, also completed successfully:
XcodeGen/build/test passed;778 Swift Testing/116 suites79.880s,20 XCTest,18 UI489.193s,0 failures.
One actual Swift start/no actual host restart. The actual PR merge tree is identical to source.
Ready/merged/physical acceptance is not claimed before independent review and final-head receipt verification.

## Implementation decisions

- One additive migration with manual-title marker and initial-model-binding tables avoids altering Codable ConversationRecord used against intentional old test schemas.
- Existing persisted empty histories have no request seed and currently become unconfigured. Provider section6 requires copying the global choice at creation; the initial idea of reading mutable global defaults on empty-history reopen was rejected before implementation. New stores its initial binding, including explicit unconfigured state. Cold reopen consumes that stored choice; historical request seeds remain unchanged.
- Original uncommitted warm page remains distinct from New. Browse uses only summaries/virtual warm projection, not new Session construction or Full timeline reads.
- A created ID is retained until bounded projection acceptance, so failed projection refresh retries the same durable empty history. Selected history then uses the existing Preview preparation owner.
- Creation binds current Soul at creation; later Send cannot rebind it. Rename/Pin update metadata only; userActiveAt is unchanged.
- Keep New creation/edit-error ownership separate from Session/Runtime ownership. Current menu captures an ID; scene/selection changes cancel its presentation.

## Remaining acceptance

Independent whole-branch review of bca95d9..9dcb508 requested changes:0 Critical,1 Important,1 Minor.
Important: successful New makes original same-process uncommitted draft inaccessible despite retaining its Session.
Accepted one test-first repair pass: draft A -> New B -> re-Lift -> bounded projection A -> exact Session/draft Return.
Unknown and deleted targets must still fail; no durable Draft row is fabricated. Correct the newly added test that incorrectly codified missing original as unopenable.
Minor deferred: Rename opens blank when the stored title is empty and Card uses the provisional first-user-text fallback.
Manual full titles and entering a new name work; no minor polish enters the fix pass.
Reviewer exclusions accepted: physical checks at Stage5 end, later slices, and process-termination Draft recovery.
Same-process recovery is required. The actual Blueprint App Space snapshot ends at section18, so the prior section19 citation is corrected to18.
Repair regression tests are written before production correction; actual compiled RED still required.

No completion claim before actual full generation/build/test CI and one fresh independent branch review.
Physical Gate A, Memory Graph, body counts, hitches, peak memory, comfort, actual VoiceOver and input acceptance remain open until Stage5 development ends.
Prior S505/H2 failure observations remain in their slice records. Green CI does not close physical acceptance.

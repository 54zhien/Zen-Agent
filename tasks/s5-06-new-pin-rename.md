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
The remaining34 cover inert metadata/manual marker/creation/window/selected-owner behavior. PR36582283469 was still running before the next tests-only publication.

## Binding-policy RED correction

Before feature implementation, Provider section6 rejected the mutable-global empty-open assumption.
The next tests-only revision adds creation-time copied binding, changed-global cold reopen, explicit unconfigured state,
exactly-once explicit Configure initialization and configured-empty LRU controls. API additions remain inert.
Old correct assertions remain; the incorrect newly drafted global-fallback case is replaced with the actual creation-time binding requirement.

## Implementation decisions

- One additive migration with manual-title marker and initial-model-binding tables avoids altering Codable ConversationRecord used against intentional old test schemas.
- Existing persisted empty histories have no request seed and currently become unconfigured. Provider section6 requires copying the global choice at creation; the initial idea of reading mutable global defaults on empty-history reopen was rejected before implementation. New stores its initial binding, including explicit unconfigured state. Cold reopen consumes that stored choice; historical request seeds remain unchanged.
- Original uncommitted warm page remains distinct from New. Browse uses only summaries/virtual warm projection, not new Session construction or Full timeline reads.
- A created ID is retained until bounded projection acceptance, so failed projection refresh retries the same durable empty history. Selected history then uses the existing Preview preparation owner.
- Creation binds current Soul at creation; later Send cannot rebind it. Rename/Pin update metadata only; userActiveAt is unchanged.
- Keep New creation/edit-error ownership separate from Session/Runtime ownership. Current menu captures an ID; scene/selection changes cancel its presentation.

## Remaining acceptance

No completion claim before actual full generation/build/test CI and one fresh independent branch review.
Physical Gate A, Memory Graph, body counts, hitches, peak memory, comfort, actual VoiceOver and input acceptance remain open until Stage5 development ends.
Prior S505/H2 failure observations remain in their slice records. Green CI does not close physical acceptance.

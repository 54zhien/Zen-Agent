# S5-07 Card Delete / Undo — execution record

## Scope and authority

Blueprint `99d30b8`, `Design/Zen Agent 开发规划.md` Stage 5 Delete step, `Design/Zen Agent App Space、Split 与全局导航.md` §§1, 6, 17–18, `Design/CONTEXT.md` lifecycle vocabulary. The upstream clock correction is recorded in `Docs/ADR/0004-card-delete-recovery-clock.md`.

This slice is stacked on S5-06 [PR #23](https://github.com/54zhien/Zen-Agent/pull/23), which is stacked on S5-05 PR #22. S5-07 is [draft PR #24](https://github.com/54zhien/Zen-Agent/pull/24). The desktop checkout remains on `main`; work is in `codex/s5-07-delete-undo`. These PRs remain unmerged for the owner's whole-stage review. Physical Gate A and later device acceptance remain open.

## Behavior

- The selected Current Card supports upward native swipe and an accessibility Delete action; New and uncommitted cards are excluded.
- The deletion owner requests Stop and waits for the Parent Run's durable cancelled terminal state before committing `pendingDeletion`.
- The persisted intent, deadline and lifecycle transition share a GRDB transaction. Messages, parts, FileAsset references and Soul binding remain intact during the Undo window. Undo does not restart a cancelled Run.
- The card leaves upward and the nearest valid predecessor, successor or New becomes Current. Browse keeps a bounded preview window.
- The original 10-second in-process window uses a continuous task sleep. Recovery after a lost timer retains the body for explicit restore/delete resolution; wall-clock time alone cannot authorize cleanup.

## RED and candidate evidence

- Persistence active-slot RED: [CI 36603146311](https://github.com/54zhien/Zen-Agent/actions/runs/36603146311), 781 Swift Testing, two new assertions failed after app/test compilation.
- Deadline RED: [CI 36607095188](https://github.com/54zhien/Zen-Agent/actions/runs/36607095188), 783 Swift Testing, seven new assertions failed. [CI 36609042237](https://github.com/54zhien/Zen-Agent/actions/runs/36609042237) then passed 783 Swift, 20 XCTest and 18 UI tests.
- Coordination and native interaction RED: [CI 36612478146](https://github.com/54zhien/Zen-Agent/actions/runs/36612478146), 792 Swift Testing, 17 new issues; 20 XCTest and 18 UI tests passed.
- First complete candidate: [CI 36615916499](https://github.com/54zhien/Zen-Agent/actions/runs/36615916499) passed 795 Swift Testing / 121 suites, 20 XCTest and 19 UI tests.
- Foreground clock regression RED: [CI 36617522605](https://github.com/54zhien/Zen-Agent/actions/runs/36617522605), app/test compilation passed; 796 Swift Testing / 121 suites failed with three new assertions in `foregroundRecoveryKeepsBodyDuringClockJump`; 20 XCTest and 19 UI tests passed.
- The follow-up candidate compiled, but its test run [36620373078](https://github.com/54zhien/Zen-Agent/actions/runs/36620373078) was cancelled by the next test-only push. It is not a GREEN receipt.

## Independent review and repair

One read-only review of S5-06..S5-07 found two Important and one Minor issue: cold-start wall-clock uncertainty could eventually erase the body; failed replacement reads could leave the deleted ID selected with a stale projection; and a recovery-read error lacked an actionable Retry control. The repair tests are on the branch before production corrections. The upstream Blueprint revision `99d30b8` resolves the clock contract using Apple's documented clock semantics; the ADR records the trade-off.

Repair tests-only tree `39d4a308b255bc056c8db11c219be7df0454fe56` passed XcodeGen, app and test compilation in [CI 36622248744](https://github.com/54zhien/Zen-Agent/actions/runs/36622248744), job `109590536451`. One Swift Testing run executed 801 tests / 121 suites and failed with exactly 10 assertions in three new cases: five in failed replacement recovery, two in live Undo after a forward clock jump, and three in cold-start preservation after the original grace. The existing 20 XCTest and all 19 UI tests passed, including native swipe/Undo; no test-host restart occurred. [Guard self-test 36622248871](https://github.com/54zhien/Zen-Agent/actions/runs/36622248871) passed. No production file changed on that test-only tree.

Repair source tree `6e898e1b43509fdd3c81b5753de60938f12f086a`, remote commit `f9f0c266471061ece8937dcdeeb38cd73c1837ba`, passed [full CI 36624971027](https://github.com/54zhien/Zen-Agent/actions/runs/36624971027), job `109599562891`: XcodeGen generation, App build, 802 Swift Testing / 121 suites, 20 XCTest and 19 UI tests, zero failures. The one Swift Testing start and all UI tests completed in a single test command; no host restart was reported. [Guard self-test 36624971008](https://github.com/54zhien/Zen-Agent/actions/runs/36624971008) passed. The repair changes only the reviewed clock and replacement-read paths, with an added explicit recovery choice test.

## Delivery receipt

The final source/test revision, remote commit `328804f9a99d17efad2c0410462e05f59357bbe2`, tree `08d7ec162db05dd521b18031fe4b96fee81f9615`, passed [full CI 36627442020](https://github.com/54zhien/Zen-Agent/actions/runs/36627442020), job `109608023892`: generation, App build, 803 Swift Testing / 121 suites, 20 XCTest, 19 UI, zero failures. The mounted UIKit accessibility Delete action passed on its real Card host. One Swift Testing start and one full UI suite completed; no host restart was reported. [Guard self-test 36627442284](https://github.com/54zhien/Zen-Agent/actions/runs/36627442284) passed. This closure-only documentation update gets its own exact-tree CI, reported in PR #24.

CI cannot establish physical performance, reading comfort, gesture error rate, actual VoiceOver behavior or device memory. The owner will review the whole Stage 5 before physical-device testing.

# S5-08 Split Targeting — execution record

## Scope and authority

Blueprint `99d30b8`, `Design/Zen Agent 开发规划.md` Stage 5 Split Targeting step, `Design/Zen Agent App Space、Split 与全局导航.md` §§2, 8, 17–18, and `Design/CONTEXT.md`. The implementation plan is [s5-08-split-targeting-plan.md](s5-08-split-targeting-plan.md).

This slice is stacked on unmerged S5-07 [draft PR #24](https://github.com/54zhien/Zen-Agent/pull/24) as [draft PR #25](https://github.com/54zhien/Zen-Agent/pull/25). The desktop checkout remains on `main`; this work is in `codex/s5-08-split-targeting`. The owner's whole-stage review precedes physical-device testing. No Stage 5 device gate is claimed closed.

## Behavior and ownership

- The existing Composer Lift transports its captured Conversation ID and native finger coordinates. Eligibility, cancellation, scene invalidation, and conversation changes clear targeting without replacing the source editor.
- Both weak, textless Drop Zones appear together. The current target follows the finger and receives one light haptic on each entry. Once Lift has activated targeting, the finger can travel back down into the lower Pane center; the activation does not reset on every subsequent sample.
- The same native Surface approaches the selected 50/50 Pane before release. Release uses the final coordinate, then an accepted consumer keeps that Surface and completes a short convergence. A missing or rejecting consumer returns it directly to Full. No second live Pane is created in S5-08.
- `SplitDropIntent` carries the captured Conversation ID and top/bottom slot to S5-09. Target geometry rejects invalid or undersized viewports. Numeric gesture and visual values remain first-pass device calibration.

## RED and implementation evidence

- Native Composer top/bottom tests were published alone at tree `bac6989550dd2879f0458f239bd8372bc3d3f073`. [CI 36632403359](https://github.com/54zhien/Zen-Agent/actions/runs/36632403359) passed app/test compilation, 803 Swift Testing / 121 suites and 20 XCTest; only the two new UI target tests failed at the absent intent probe. Existing 19 UI tests passed.
- First implementation tree `da16d956288608b1cd01157863e6c0a95ccad405` passed the app build, but [CI 36635144601](https://github.com/54zhien/Zen-Agent/actions/runs/36635144601) found an ambiguous `.nan` in a new test. [CI 36635681757](https://github.com/54zhien/Zen-Agent/actions/runs/36635681757) then found an existing Composer fixture missing the new Conversation ID. These were test-target compile errors, not behavioral results.
- The fixture repair tree `a86cb87da3c7265b4867d689eb0fa19ee3446643` passed [CI 36636116839](https://github.com/54zhien/Zen-Agent/actions/runs/36636116839): XcodeGen, app build, 809 Swift Testing / 122 suites, 20 XCTest and 21 UI tests, zero failures. [Guard self-test 36636116829](https://github.com/54zhien/Zen-Agent/actions/runs/36636116829) passed.

## Read-only review and repair

Review found three important behavior gaps: target activation was not latched, final release coordinates were not forwarded, and an accepted drop still animated to Full. It also asked for stronger source-change and reading-position coverage. A test-only tree `99beb81366a72e4110579b363d926ff2cf781ef7` passed compilation in [CI 36638889365](https://github.com/54zhien/Zen-Agent/actions/runs/36638889365). Of 811 Swift Testing cases / 122 suites, only the two new host cases failed, with six assertions at the expected lower-target and accepted-handoff behavior. All 20 XCTest and 21 UI tests passed. [Guard self-test 36638889338](https://github.com/54zhien/Zen-Agent/actions/runs/36638889338) passed.

The repair latches activation, samples `.ended`, gives accepted Split its own settlement and native convergence, and adds stale-source, state-return, and reading-position checks. Its first exact source/test tree `d16eb193c6c5ba4f471eec14f9fceb901e8a0709` passed generation, app build, 20 XCTest and all 21 UI tests in [CI 36640751771](https://github.com/54zhien/Zen-Agent/actions/runs/36640751771). Of 814 Swift Testing cases / 122 suites, only one new assertion failed: it expected Full synchronously while the intentional Return animation was still settling. The test now asserts a Full-bound settlement first and waits for animation completion before checking Full. The corrected test and closure documentation await final exact-tree CI.

## Boundary and open acceptance

S5-09 owns the actual two-Pane Split Container, empty Pane Picker and Divider. Until that consumer is installed, a drag safely returns to Full. S5-09 must provide an accessibility-equivalent Split entry and verify two distinct Pane/Session owners; this slice alone does not claim usable Split. Physical gesture comfort, haptic feel, VoiceOver behavior, performance and memory remain for the owner's later device review.

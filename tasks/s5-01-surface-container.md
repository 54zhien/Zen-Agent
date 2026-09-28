# S5-01 — Conversation Surface container

## Contract and baseline

Plan: `Zen-Agent-Stage5-Plan-2026-09-28.md`, section 6. Only S5-01 is in scope.
Base: `f400621c9d969e796136aaa9dc3024d37520594c`.
Blueprint: `596a84d4b58769e3e7b838be95edcb43f9e0ec82`; authenticated reads of the
stage index, CONTEXT and App Space/Split/navigation note on 2026-09-28 confirmed
the current baseline.

The stable UIKit container owns only presentation. It contains one
UIHostingController for the existing complete NavigationStack, including toolbar
and original sheets. It does not own a Pane, Runtime, database or command service.
The existing Pane remains the owner of Composer, reading and live state.
Progress changes transform/corner radius, never the child's layout dimensions.
Geometry uses the host's local viewport and safe area, with normalized translation
fractions. No global screen size, navigation gesture or additional editor.

Finite progress is clamped to 0...1. Nonfinite progress, invalid endpoints,
nonpositive/invalid viewport or safe area and overflowing output reject the update
and preserve the last valid presentation. Returning uses the same request at
progress zero. No asynchronous transition/epoch is introduced before S5-03.
Production stays Full. DEBUG-only test progress is a controlled fixture, not a
user-facing navigation affordance or production card geometry.

## Change whitelist

- `App/Workspace/SurfaceGeometry.swift`: pure validation/interpolation.
- `App/Workspace/ConversationSurfaceHost.swift`: stable child containment and visuals.
- `App/AppShell/NewConversationView.swift`: ready-root wrapper only.
- `App/ZenAgentApp.swift`: DEBUG fixture routing only.
- Surface Unit/UI tests and a dedicated DEBUG fixture.
- This evidence record; existing records and `tasks/todo.md` remain intact.

No dependency, migration, Runtime/Router/Assembly or Composer implementation change.
XcodeGen already recursively includes App and both Tests directories. Build settings
remain in Config; generated project is ignored.

## Verification ledger

Pure-new RED exception follows plan section 6.4: the first new geometry resolver is
a deliberate, compilable Full-only mutation. Tests demand literal interpolated
scale/translation/corners and invalid-update rejection. A missing type or compiler
error is not counted as RED.

- RED candidate: `0a250df68fe76ea4467185212015dd7f1ce5acf4`.
- RED PR CI: [run 36371128667](https://github.com/54zhien/Zen-Agent/actions/runs/36371128667),
  attempt 1 — App build passed, test compilation failed on two ambiguous CGSize.infinity expressions. This is not behavioral RED.
- Corrected RED candidate: `7a1001107dc5936c52734b69b170a296da664511`: [run 36371366650](https://github.com/54zhien/Zen-Agent/actions/runs/36371366650), attempt 1, App build passed; tests failed compilation on ambiguous CGSize.greatestFiniteMagnitude. Not behavioral RED.
- Further corrected RED candidate: `2b7ed88f38c6efa313eae075156d5bcbe1a368d1`; all ambiguous CGSize extreme values use explicit CGFloat. Compiled behavioral RED: [run 36371673396](https://github.com/54zhien/Zen-Agent/actions/runs/36371673396), attempt 1, XcodeGen/App build passed; 660 Swift Testing cases in 104 suites ran with 44 expected issues (40 geometry, 4 host presentation). Editor-owner/draft/state round-trip and release tests passed, as did the original 2 UI tests. No test-host restart.
- Diagnostic test-only candidate `588b3887f87943cbfb5dc44b2a00f0e24b683ad9` was prepared while the RED job was slow; archived logs showed normal test execution (50.169 seconds) rather than a stalled host. Its now-redundant stage prints are removed in GREEN; all assertions remain.
- GREEN implementation `377c0cdfb5e4c6a187a3acfeac3e3871f58f4e32`: [run 36372722931](https://github.com/54zhien/Zen-Agent/actions/runs/36372722931), attempt 1 passed XcodeGen, hygiene, App build, 661 Swift Testing cases/104 suites, 20 XCTest unit tests and 4 UI tests. Counts are from this run's logs; fetched PR merge tree matches the implementation tree. Guard self-test run 36372722943 passed.
- Independent whole-branch review of base through `377c0cd`: no Critical issue or confirmed production defect; one Important verification gap and one Minor stale-ledger issue. The unit reading/live assertions do not render Timeline. Follow-up adds a real long-history Surface progress regression using the existing Pane fixture: affine-normalized older Turn geometry, reading mode, live delta and Full return/new-content action. Existing editor/draft tests remain. This is an additional acceptance test, not a production behavior change; its first CI result is pending. The Minor ledger issue is corrected here.

The GitHub CLI/Git write credential was unavailable. The authorized connector
uploaded the local committed tree; remote tree `6f9e3beb3723bde9672881a0ccff8e785dad3127`
matched the local tree exactly. The worktree was aligned to the fetched remote
commit with a soft reset after matching the tree; no source content was replaced.

## Device acceptance

Not performed on Windows. Record the installed source/build, device and iOS version
before checking repeated transform/return, input and Send/refocus, long-history
reading, keyboard show/hide, configuration-sheet return, Dynamic Type and VoiceOver.
No animation smoothness, memory or 60/120 Hz claim is made from simulator CI.
No IPA was requested or produced. This slice does not close Stage 5 or Gate A.

## Follow-on boundary

S5-02 is not started. Session/configuration retention, preview virtualization and
Router replay remain S5-04; creation/Soul binding remains S5-06; cancellation and
deletion remain S5-07. Reading anchors stay in process; this slice introduces no
cross-process anchor or Draft persistence. The older Stage 5 entry's open-anchor
wording is superseded by the plan's already-approved no-persistence decision.

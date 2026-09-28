# Stage 5 entry and Stage 0–4 closeout

Recorded on 2026-09-28. Stage 5 feature implementation has not started.

## Integrated baseline

- Stage 0/1 are closed; Stage 2 Runtime/Tool boundaries are integrated.
- Stage 3 W1, keyboard/reading-position repair and UI harness are integrated.
- Stage 4 Prompt/Soul implementation is closed in [stage4-closure.md](stage4-closure.md).
  The Soul editor remains dependent on formal Settings navigation.
- PR #14 merged at `f775e63610840bc022730f8dfb5e987ad8e498d5`, with head
  `8ee851682475a58cf1e4acf2992e62f68a7ef4d0`. It settles orphaned streams without
  replay, attaches proven frozen continuations/approvals, preserves partial output
  on abnormal Provider finishes, keeps history readable without a usable Send
  target, and advances activity only on committed new user Sends.
- The open-PR audit found only #14 before integration. Earlier Stage 4 stacked
  drafts #6–9 were closed after their changes entered #10; they need no separate merge.
- No schema migration, new dependency or IPA was produced for #14 or this closeout.

## Verification evidence

- [Repair head push CI](https://github.com/54zhien/Zen-Agent/actions/runs/36348399515):
  hygiene, XcodeGen, App build, 654 Swift Testing cases in 102 suites, 20 XCTest unit
  tests, and 2 UI tests passed on `8ee8516`.
- [Repair PR CI](https://github.com/54zhien/Zen-Agent/actions/runs/36349052785):
  first attempt passed unit tests but failed the Composer quick-focus UI test while
  synthesizing keyboard input after Send. The same SHA passed a failed-job rerun.
  This is recorded as an intermittent CI observation, not proof of device behavior.
- [Build-settings guard self-test](https://github.com/54zhien/Zen-Agent/actions/runs/36349052903) passed.
- Per-repair compiled RED/GREEN evidence is preserved in [PR #14](https://github.com/54zhien/Zen-Agent/pull/14).

## Blueprint access and scope

The upstream Blueprint is private. Authenticated access was verified on 2026-09-28;
its latest recorded commit is still `596a84d4b58769e3e7b838be95edcb43f9e0ec82`.
The current stage plan, `Design/CONTEXT.md`, and App Space/Split/navigation note
were read through the authorized connector. An unauthenticated 404 is an access
result, not evidence that the design repository was deleted. No design baseline
change was required for this closeout.

Stage 5 starts with an audit of the real UI root, Pane ownership and gestures, then
a Surface Container slice: Full Conversation can scale, round its corners and
return continuously. Keep existing Run/Composer/scroll ownership; do not build
App Space data, Split, Sidebar or Settings in that first slice.

Continue in Blueprint order: static geometry → Lift/Return → preview virtualization
→ browse/snap → New/Pin/Rename → Delete/Undo → Split targeting/container/resize
→ orientation → Sidebar → Search → Files → Settings IA → visual enhancement.
Agent configuration stays under Settings → Agent, with Soul at Settings → Agent → Soul.

Before their affected slices, resolve the Blueprint's outstanding decisions on
App Space in iPhone landscape, Sidebar trigger/gesture arbitration, Split Lift
return, landscapeSingle operation ownership, IME handling during navigation,
Light Mode App Space, and cross-process scroll-anchor persistence. Do not silently
choose a product policy or interpret these as completed work.

## Device evidence still owed

The owner reported the Stage 3 device Gate closed on 2026-09-27. That progression
decision remains recorded; D1–D7 observations, installed source/build, and signing
method have not been supplied. The old `840a2e2` IPA predates both #12 and #14.
It cannot validate their fixes.

Use [stage3-device-acceptance.md](stage3-device-acceptance.md) for those checks and
the #14 force-quit recovery, unavailable-credential history and Composer follow-up.
Measure device performance/memory and check Dynamic Type/VoiceOver before claiming
those acceptance items. This closeout does not mark unobserved checks as passed.

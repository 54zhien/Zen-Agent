# Focused Stage 5 Pad readiness review

## Reviewed identity and scope

- Candidate local HEAD: ff036165dd5e0d9f81684a09282977f0bafb7fd7 (short ff03616), tree d4ffc8b78512dba5004c8915c3bbf654dfbabe8c; parent reports remote commit ab5cd44 has the same tree.
- The App, Tests, Config, Resources, and CI content matches the previously reviewed source at 174c23cad7e9bb1fda698e6fcab166cf5a9dde20 (tree 79f55ccb5d2ff9558eaae8e5111830f409ecca91). The candidate's base-to-HEAD changes are closure/review documentation only; this assessment does not identify a production-source change.
- Focus: the landscape readiness assertion in Tests/ZenAgentUITests/WorkspacePadAxisUITests.swift:33, its adjacent split-pane setup, and the supplied PR Pad log. No source or test files were changed and no tests were run during this review.

## Evidence

PR run 37252198078, Pad job 111581981090, compiled and launched the actual Pad UI test. In visual-final-pr-pad.log, both identified pane scroll views pass their separate existence waits before the failing assertion. At about 31.71 seconds XCTest begins querying the target application for the global app.frame; it queries again around 41.01 seconds and then reports the waiter timeout at line 33. The assertion currently evaluates app.frame.width > app.frame.height, which reads the global application frame twice during each predicate evaluation.

The same test proceeds after recording that failure. Its native axis readiness probes report the expected top/bottom and left/right configurations; the resize log records source frame (0, 0, 777.5, 1032) and other-pane frame (777.5, 0, 598.5, 1032). The supplied native probe evidence reports a 1376x1032 workspace and correct native source/other hosts. The remaining ratio and editor-identity assertions pass. The job has one reported test assertion failure, without a compile failure, host restart, or job timeout. The separate Push Pad pass does not turn this PR Pad result green.

## Assessment and focused correction

The evidence supports a test-observation problem at the readiness gate: it asks XCTest for the global application frame after both relevant pane elements were already found, and that application-level accessibility query stalls until the predicate waiter expires. The later pane geometry and native probes show that the test has the precise workspace surfaces available to observe directly. This is a test-level diagnosis from the trace; it does not establish that every simulator run will behave identically.

Preserve the landscape prerequisite, but evaluate it from the union of the two live pane frames. On every predicate poll, sample source.frame once and other.frame once; require both sampled CGRects to be finite, non-null, non-empty, and to have positive width and height; then form their union and require the union's width to exceed its height. The frames are reported in the same app/screen coordinate space, and the union represents the combined split workspace. Fetch fresh frames on each poll so the wait observes orientation settling rather than using a pre-wait snapshot. This keeps the orientation assertion meaningful while removing the observed global-app-frame query from this readiness predicate.

Keep the existing independent pane-existence waits, axis changes, ratios, native editor identity checks, and final existence assertions. Keep the app-coordinate divider drag anchor and its current app.frame use unchanged; it serves a different purpose after readiness and is tied to gesture coordinate conversion. Do not weaken the gate, add timeout/retry behavior, skip the test, or mutate app state directly.

## Limits and next validation

This is a focused review of one compiled Pad test failure, not a re-review of Stage 5 and not physical-device acceptance. The log supports the proposed observation correction but cannot prove it will pass. After that test-only correction, rerun the real Pad UI job and evaluate its complete result; retain this PR failure as RED until a successful rerun exists. Physical keyboard/IME, VoiceOver, comfort, and GPU/frame-pacing checks remain outside this code-only assessment.

## Review of the in-progress test-only diff (2026-10-05)

I inspected the uncommitted diff for WorkspacePadAxisUITests.swift. It contains one hunk at the landscape readiness gate. This test file is the only changed test/production source path; handoff documentation was also updated and is outside this narrow code review. For each evaluation of the existing expect predicate, source.frame and other.frame are each read exactly once into local CGRect values. The guard rejects null or empty frames and requires positive width and height; it also checks finite minX, minY, width, and height components for each sampled frame. The union is then computed from those same snapshots, and both union dimensions must be finite before width > height succeeds. This preserves a real landscape gate while avoiding another frame read inside the predicate.

The existing expect helper still uses its 10-second XCTWaiter timeout. The separate pane waitForExistence timeouts remain 10 seconds; the iPad-only skip guard is unchanged. The app-coordinate divider anchor still captures app.frame after readiness and uses it for normalized drag coordinates exactly as before. The axis transitions, resize/ratio checks, lease checks, editor-identity assertions, and final existence assertion are unchanged in the diff. No retry or timeout extension was introduced.

I also inspected external capture pad-final-frame-38.png. Its image is encoded in portrait natural orientation, while the capture content corresponds to the actual landscape workspace with the two panes stacked top/bottom as described in the supplied capture note. That supports retaining a landscape prerequisite; it does not show that the failed UI test has passed.

Review conclusion: the in-progress test-only change matches the requested narrow correction and leaves the other gesture and behavior checks intact. This is static diff review only; no test was run and no result is inferred for the corrected gate.

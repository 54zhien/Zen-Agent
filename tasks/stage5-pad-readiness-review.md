# Focused Stage 5 Pad readiness review

## Reviewed identity and scope

- Candidate local HEAD: `ff036165dd5e0d9f81684a09282977f0bafb7fd7` (short ff03616), tree `d4ffc8b78512dba5004c8915c3bbf654dfbabe8c`; parent reports remote `ab5cd44` has the same tree.
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


## Addendum: follow-up PR Pad readiness failure (2026-10-05)

### Reviewed candidate and new evidence

- Candidate local HEAD: `3de65208213ac4996580f663d46e7aa376eda3b6`, tree `3e518507360d8476487a844bc8057768a015f57d`; parent identifies pushed candidate `a260c8e91bd59a643616578c3461ad7870d96e7e` with the same tree. The PR log checked out merge ref `b67e620` (candidate `a260c8e` into base `2d501a6`).
- PR Pad job `111592847720` (log: `visual-readiness-pr-pad.log`, artifact `11322354710`). This review is limited to the landscape readiness gate and the proposed one-shot observation change. I made no source/test/documentation changes and ran no tests.
- The separate pane-existence waits pass at about 34.34s and 35.44s. The predicate begins a `source.frame` query around 38.08s; XCTest retries it and collects a snapshot through about 47.40s. The `other.frame` query begins around 47.41s and also retries; the 10-second predicate waiter fails at line 35. The later native probe query itself stalls from about 48.04s to 79.90s. Subsequent axis, resize, ratio and editor-identity checks pass. The test still has a real PR Pad validation failure.
- The supplied native video frame at 45s shows the workspace in landscape with top/bottom panes. That is evidence of the displayed orientation at that point, but the failed gate did not produce CGRect values, so it does not establish what either AX frame contained when queried. The separate Push Pad pass (95.749s) does not make this PR Pad result green.

### Assessment of a one-shot post-existence assertion

Taking each pane's fresh `CGRect` once after the two existing existence waits, then directly asserting that each rectangle is finite, non-null, non-empty and positive and that their finite union has `width > height`, preserves the same hard geometric landscape condition. The union is a meaningful workspace measurement: `SplitWorkspaceGeometry` partitions the viewport into two pane rectangles whose union covers that viewport. A portrait or invalid sampled workspace still fails; the proposal does not relax the asserted geometry.

This is narrower than rewriting the shared predicate-wait helper. It removes the expensive AX frame reads from repeated evaluations under the existing 10-second predicate waiter and avoids repeated reads within that gate. Keep the current existence waits, all later axis/ratio/editor assertions, the app-coordinate divider-drag anchor, and all existing timeouts and skip behavior.

There is one timing distinction to make explicit: the current predicate waits for landscape geometry to become true, while one-shot assertions require it to be true at the first sample after both panes exist. That keeps the value-level invariant and makes a false pass less likely, but it no longer waits for orientation/layout settling. It can therefore produce a legitimate test RED if pane existence precedes landscape geometry becoming ready. No evidence here proves that the two existence waits imply settled geometry. If the test contract is “workspace must already be landscape at this point,” the one-shot assertion is appropriate; if the contract is “wait until landscape geometry is ready,” it changes that timing contract.

The one-shot form is not guaranteed to eliminate AX stalls: an individual `XCUIElement.frame` getter can still block or retry internally. It avoids spending repeated getter time inside the predicate wait, but only a real Pad run of the candidate can show whether the observation now completes reliably. Keep this PR gate RED until that candidate's actual Pad job passes; do not infer a production defect or a fixed root cause from this log.

Apple documents that an `XCTNSPredicateExpectation` predicate is evaluated on the main actor when Swift awaits `fulfillment(of:timeout:enforceOrder:)` rather than calling `wait(for:)` ([Apple XCTest documentation](https://developer.apple.com/documentation/xctest/xctnspredicateexpectation/init(predicate:object:))). The current helper uses synchronous `XCTWaiter.wait(for:timeout:)`; the documentation distinction is useful threading guidance, but does not identify the cause of this failure.

### Conclusion

The proposed direct capture and hard geometry assertions preserve the landscape requirement and are the narrower observation change. Treat them as a one-shot assertion after pane existence, with the timing caveat above—not as proof that the prior pane-frame predicate correction fixed the CI failure. No extra native evidence is needed to assess whether the union condition preserves the orientation invariant; the candidate's actual Pad run is still required to validate the observation path.




## Review of the written one-shot gate diff (2026-10-05)

The actual test diff changes only the first readiness gate in Tests/ZenAgentUITests/WorkspacePadAxisUITests.swift. The test method is MainActor-isolated. After the existing independent 10-second pane-existence waits, it reads source.frame once and other.frame once, forms their union from those samples, and prints both frames and the union. The invalid-geometry guard rejects null, empty, non-positive, or non-finite pane rectangles and a non-finite union; that path records XCTFail and returns. A valid union must then satisfy the direct width-greater-than-height assertion. Thus an invalid or portrait first sample remains a test failure, with no predicate polling or added timeout.

The diff leaves the rest of the test intact, including all native axis transitions, resize/ratio and editor-identity checks, the app-coordinate divider-drag anchor, the existing expect helper and its timeouts, and the iPad skip. It changes test observation only; no production source changed. One assertion detail: XCTAssertGreaterThan records a failure but does not abort the test, so a valid portrait sample is a real RED while later assertions and interactions still run, as they did after the prior waiter failure. No tests were run during this review.

Parent confirms PR merge commit b67e6206015cd17aeb9ce6ae5d9e08b75e3c9a2d has tree 3e518507360d8476487a844bc8057768a015f57d, identical to the reviewed candidate tree. This identity confirmation does not provide validation evidence for the new working-tree test diff. Keep that diff unverified until its actual Pad CI result is available.

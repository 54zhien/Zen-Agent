# Stage 5 Dock focus repair — 2026-10-08

This record describes a reproduced production focus bug. It does not close
Stage 5, the original intermittent PR failure, or physical-device acceptance.

## Current integration status: blocked

The original `preserveOutgoing=false` settled-focus failure reproduced again
when selected alone on a cold simulator, without the notification fixture.
The fixes below remain valid independently; they do not resolve that original
failure. PR #35 is not merged, and no verified main integration commit M exists.
The independent iPad first-Sidebar-gesture failure also remains unresolved.

## Reproduced stale blur

The incoming Pane bridge can receive `isActivePane=true` while its draft is
still resting, before the outer Dock receives the new active Conversation.
These updates belong to separate hosting trees. When the Dock transfers the
native responder, `didBeginEditing` publishes `.editing` through the real
ComposerController before the bridge has delivered its next configuration.

An unchanged Dock refresh during that gap used to call `applyFocusIfAttached`
again with the portal's cached `focused=false`. This resigned the incoming
editor, published `keyboardDismissed`, and returned its model to `.resting`.

The paired native regression manually drives that valid update order using
the production Dock, portals and ComposerController. The control delivers
feedback before another refresh; the experimental arm refreshes first.
Both retain incoming immediate/settled focus, outgoing blur, separate text,
model editing state, and subsequent explicit blur checks. This test does
not claim to execute SwiftUI's scheduler itself.

## Minimal production change

`ComposerDockContainer.install` now maintains the external owner and retries
only positive focus requests when the same portal is already installed.
`ComposerHostPortal.update` remains responsible for applying new focus and
blur requests. First installation
still transfers native focus before parking the outgoing portal. No runtime,
draft, persistence, IME policy, or Stage 6 code changed.

## Actual RED and GREEN

- RED source: `cadef7f47d91e1617164b2fb3a8105ae8bef36bf`.
  [Run 37754272146](https://github.com/54zhien/Zen-Agent/actions/runs/37754272146)
  generated and built the app, then reported four assertion issues, all in
  the refresh-before-feedback arm. The control, original false/true cases,
  and five bounded diagnostic attempts had no issue. Hygiene and Pad passed.
- GREEN repair source: `ec6b370a426aa37d58a3570545ee76a7f2ec721e`.
  [Phone job 113242620477](https://github.com/54zhien/Zen-Agent/actions/runs/37756597521/job/113242620477)
  passed all four test functions in one suite, including both regression
  arms and the original cases. This targeted run is not the full CI gate.
- Related focus group and final profile-free CI must have their own actual
  receipts before this source is described as fully verified.

## Review correction: pending focus before window attachment

Fresh review identified an Important regression in the initial repair:
removing all same-owner retry also lost a positive request made before the
container joined a window. Ordinary `didMoveToWindow` does not retry that
request; a later unchanged Dock refresh must still do so.

The additional native regression installs the portal outside the window,
attaches the container, refreshes the same Dock, checks immediate/settled
focus and retained text, then verifies explicit blur remains effective.
Test-only source `ecd63977f6d954c5b8d46d74d9eb9c69dfd6e4d7` produced actual
[RED 37759119052](https://github.com/54zhien/Zen-Agent/actions/runs/37759119052):
exactly two focus assertions failed in that new case; the original cases
and stale-blur paired arms passed. Hygiene and Pad also passed.

After that RED, repair source `8d02a07e172943d24dbf24a935db2bdea5f67e9f`
introduced `allowResignation=false` only for an unchanged installation.
Positive retry is retained; cached false cannot revoke transferred focus;
default bridge updates retain explicit blur and marked-text protection.
Its [targeted GREEN 37761181748](https://github.com/54zhien/Zen-Agent/actions/runs/37761181748)
passed all three jobs. Phone ran four test functions in one suite, including
the original false/true cases, both stale-blur arms, and late-attachment /
explicit-blur checks. Pad and hygiene passed. The temporary trace and
five-repeat probe were absent in this run. The subsequent
[related-group run 37762813052](https://github.com/54zhien/Zen-Agent/actions/runs/37762813052)
also passed all three jobs: 156 Swift tests / 11 suites on Phone, Pad and
hygiene. This is the same `8d02a07` production/test source. Final complete
CI on the diagnostic-free publication commit remains pending; neither
targeted nor related-group GREEN is a complete gate.

## Original blocker remains distinct

[Run 37727202467](https://github.com/54zhien/Zen-Agent/actions/runs/37727202467)
failed the original outgoing-first case after 250 ms, with the incoming
editor attached to the key window. That fixture had a no-op focus callback
and did not perform the duplicate refresh reproduced above. Its cause has
not been established. Diagnostic runs passed, which does not prove a fix.
Do not attribute that failure to this stale-blur path without new evidence.

PR #35 remains open; no actual main integration commit M exists. The user
authorized a normal merge only after the Stage 5 blocker is repaired and the
candidate passes review and complete CI. Stage 6's worktree and branch are
outside this executor's scope. No IPA was built. Device acceptance and the
previously disclosed SQLite cleanup warnings remain open. The supplied
Minecraft screenshot is separate from Zen Agent and is not fixed here.

## Archived failure decoding and fixture isolation

The subsequent original xcresult export identifies the failed focus window as
context `5777F084`. In its system log, the keyboard task queue timed out at
04:36:24.157; SpringBoard disconnected that same input context with an outstanding
assertion at 04:36:28.024. KeyboardManagement XPC invalidation and input-session
teardown preceded the focus assertion at 04:36:29.092. The test window did not
resign key until cleanup at 04:36:29.139. Thus this failure included keyboard
service disruption while the editor's window remained attached/key; the log
does not identify what originally caused the service timeout.

The preceding notification-only fixture unnecessarily made a temporary window
key, restored the previous key window, and produced an unbalanced root-controller
appearance warning. It only exercises screen-scoped keyboard notifications and
requires a window-attached view, not a key window or a root-controller appearance.

A regression invokes that fixture while another window contains a focused
editor, observing key resignation plus immediate/settled responder and text:

- [RED 37775902495](https://github.com/54zhien/Zen-Agent/actions/runs/37775902495),
  source `29ea80e0487a10b690489294719af268261be305`: Phone job `113306532331`
  generated/built and reported exactly one issue, the editing window's key
  resignation count was 1 instead of 0. Its responder/text checks and existing
  focus cases passed. This reproduces fixture interference, not the historical
  delayed-loss assertion.
- [GREEN 37777967269](https://github.com/54zhien/Zen-Agent/actions/runs/37777967269),
  source `137dcdd99c718a8e0512e868c6744211f9ed811d`: Phone job `113313522695`
  passed all 5 test functions / 1 suite after removing key presentation and the
  unused root controller. All original notification and focus assertions remain.
  The overall run failed in its independent Pad diagnostic job; it is not a
  complete-CI success.

This establishes the fixture's unnecessary key-window side effect and its
removal. It does not establish that the earlier brief key change caused the
historical keyboard-service timeout. Synthetic notifications remain screen-wide;
the new regression proves key/responder/text preservation, not isolation of every
other keyboard observer. No global test-parallelism policy was changed.

Review also found that the new regression initially ran before the original
focus cases and could warm the keyboard service. It has been moved after the
existing cases, and a separate cold selected execution of only the original
false/true case is required to control for that ordering effect. Source order
alone is not used as an execution guarantee. That cold selection subsequently
failed as documented below; its dependent related-group step did not run.

The diagnostic source pushes are not release candidates. Their cancelled
standard CI runs are not acceptance evidence. The original `e829d85` source CI
[37764831983](https://github.com/54zhien/Zen-Agent/actions/runs/37764831983) passed,
but its [PR run 37764837454](https://github.com/54zhien/Zen-Agent/actions/runs/37764837454)
failed the actual Pad's first Sidebar opening. That independent native failure
remains under investigation; PR #35 is not merged and no M exists.

## Native Sidebar investigation: no accepted production repair

The Pad first-edge failure is independent of the Dock fixture correction.
Temporary probes preserved the original one-drag opening assertion:

| Probe | Actual result | Limit |
| --- | --- | --- |
| `37775902495` / Pad `113306532025` | Both first-edge landscape cases passed | No failure reproduced |
| `37777967269` / Pad `113313523239` | 4 tests, 1 failure: ordinary right-landscape opening; both deliberate event-stall comparisons passed | Does not support slow drag as a repair |
| `37781102671` / Pad `113324112106` | 4 tests, 1 failure in broad-priority left-landscape; both scroll-pan-only variants passed | Uses a diagnostic recognizer subclass |
| `37783352703` / Pad `113331753936` | Base system recognizer: 12 fixed attempts across orientation/policy, all passed | Both baseline and comparison passed; priority hypothesis unproven |

In the failed subclass trace, the same recognizer/interaction remained mounted
through 11 moves and `.began` to `.ended`. Neither its interaction target nor an
independent target received an action. The first detach occurred during later
rotation cleanup. Full system decoding (`37785953572`) adds UIKit action/reset
and SpringBoard failure-requirement events, but does not identify a responsible
dependency or establish equivalence with the original production-recognizer
failure, which had no `shouldBegin` callback.

Accordingly, no priority narrowing, gesture replacement, drag-speed change, or
extra wait is accepted as a production fix. All temporary probe workflows,
recognizer subclasses, extra action targets, fault injection, and environment
switches have been removed. The Sidebar production source is byte-equivalent to
`e829d85`. Original full-CI workflows and all original test assertions remain.
The bounded probe results are investigation evidence, not a claim that the
historical Pad failure is resolved. Main integration remains gated.

## Original cold focus failure and bounded controls

[Cold run 37784846258](https://github.com/54zhien/Zen-Agent/actions/runs/37784846258)
on `fd613e2143200445e6eabd51c887c28f7eee5951` generated and built the app, then
selected exactly the original function and both parameters. The false case
failed settled B focus, with `keyWindow=true` and `attached=true`; immediate
B focus and the true case passed. No notification fixture or keyboard-warming
regression ran. This rules out that fixture as a necessary trigger.

The archived xcresult was decoded in
[37791959704](https://github.com/54zhien/Zen-Agent/actions/runs/37791959704).
Its events identify the immediate resignation path:

| UTC event time | Observation |
| --- | --- |
| 13:51:52.072 | App-side first keyboard `willShow` |
| 13:51:52.284 | A's input-session teardown |
| 13:51:52.344 | SpringBoard keyboard `didShow` |
| 13:51:53.364 | App keyboard-task queue timeout |
| 13:51:57.013 | KeyboardManagement hosted connection timed out and invalidated |
| 13:51:57.464 | UIKit KeyboardArbiter client explicitly logged `resignFirstResponder` |
| 13:51:57.467 | B's `UITextView` input-session teardown |

This identifies a native keyboard-arbiter resignation after connection loss.
It does not establish what caused the timeout, nor establish that the fault
belongs to the simulator rather than the app's use of UIKit.

The following controlled runs are diagnostic evidence, not accepted repairs:

| Run / source | Result | Interpretation |
| --- | --- | --- |
| [37789542184](https://github.com/54zhien/Zen-Agent/actions/runs/37789542184) / `98878c1` | Three fresh jobs passed: plain UITextView in a new window, plain UITextView in the app window, direct ComposerHost in a new window | Direct mounts omit controller ancestry; synchronous trace printing also affects timing. No window or Composer exoneration. |
| [37791795003](https://github.com/54zhien/Zen-Agent/actions/runs/37791795003) / `6b5a0af` | Original Dock and app-window Dock each passed both parameters | App-window arm still logged a keyboard-queue timeout without losing focus. Queue timeout alone is not sufficient; changing window is not a demonstrated repair. |
| [37795010711](https://github.com/54zhien/Zen-Agent/actions/runs/37795010711) / `9d4a7ec` | Original 250 ms, first-willShow/during, and didShow/after arms all passed both parameters; all event gates were reached | Original and during arms transferred before didShow. Waiting for didShow is not established as the required fix. |

The timing experiment's first source, `bd70f2d`, failed compilation in
[37793840883](https://github.com/54zhien/Zen-Agent/actions/runs/37793840883):
a non-Sendable Notification was captured across an actor boundary. That was
corrected by extracting only its screen identity before actor isolation.
No behavior test ran on the uncompilable source; it is not a behavioral RED.

The original assertions, parameter cases, 250 ms checks, and production focus
behavior are retained. No extra keyboard-readiness wait, retry, swallowed
resignation, new gesture priority, or simulator-version change has been
accepted as a fix. Temporary control tests, source trace hooks, and diagnostic
comparison workflows are removed. Their immutable source commits, logs, xcresults, and
hash-checked local archives retain the investigation evidence.

The independent UIKit-only project on `4a80d18` imports no ZenAgent code or
SwiftUI. Its during/after cases passed both parameters in run `37795890659`.
The original-timing job did not execute in attempt 1: GitHub reported that no
hosted runner acquired the job and noted macOS arm64 capacity constraints.
Only that unexecuted job was resubmitted; no failed behavior was retried.
Attempt 2's job `113385490657` passed the original-timing function and both
parameters, with one suite, no test-host restart, and `TEST SUCCEEDED`. The false
case requested outgoing resignation before didShow and retained B focus after
250 ms. All three independent arms therefore passed; this does not reproduce
the original fault or prove that it is a system defect. Both attempts' metadata,
capacity annotations, logs, and three xcresults are archived with SHA-256 checks.

The cold RED's native fault explicitly contains `Last Exception Backtrace:
No stack!`. A temporary `stage5-cold-stack.yml` therefore selects the unchanged
original function once and externally samples the app's threads for 30 seconds.
It adds no app hooks, focus readiness, keyboard warmup, or test assertion change.
This is a bounded attempt to identify the call waiting on the keyboard queue;
sampling can affect scheduling, so a passing sample does not establish a repair.
Sampling failures must be distinguished from test failures. This evidence-only
workflow was removed after the result below, before the next complete CI gate.

[Stack capture 37799578964](https://github.com/54zhien/Zen-Agent/actions/runs/37799578964)
on `0f6746aa45cf0772ff4664d718b7f64394b7701f` generated, built, and passed the
original function with both parameters (one suite, 7.006 seconds, no host restart).
The sample identified the actual simulator ZenAgent process, PID 23501, and
completed successfully with a symbolicated main-thread graph. Its 30-second
capture began at 15:30:54 UTC and overlapped the test around 15:31:14–21.
The graph includes the original test's initial A-focus path through
`ComposerDockContainer.install` and `ComposerHostView.requestFocus` into UIKit.
It contains no `_lockWhenReadyForMainThread` or `resignFirstResponder` sample;
the test log has no keyboard-task-queue timeout or XPC failure. Consequently
it supplies a passing reference stack, not the missing failure stack or a fix.
Logs/sample archive SHA-256: `6937077390d1a4bbec1f18ad3f1d76c9897edd45a588705b3da79fedcf307629`.
xcresult archive SHA-256: `53d46c15e7ed71269d8280103332b03ef5b2faf3d4a3b54caa9e12c746c7352a`.

The next missing evidence is the trigger preceding the native connection
timeout, plus the iPad admission-to-begin failure. Passing samples above cannot
replace those missing causal results. No final complete-CI acceptance or main
integration is claimed for this checkpoint.

## Clean-source complete CI: original failure reproduced again

Source `19423a448c318bfba7da7f18fc33a25b968c699f` / tree
`1012621d43a0a07575eb3916711bee57c8933c99` contains no temporary diagnostics.
Its [PR CI 37801917220](https://github.com/54zhien/Zen-Agent/actions/runs/37801917220)
passed 987 Swift tests / 158 suites, 20 XCTest, 61 Phone UI tests (one expected
Pad-only skip), and actual iPad 1/1, with no host restart. Guard self-test
`37801917243` also passed.

The same source's [push CI 37801912044](https://github.com/54zhien/Zen-Agent/actions/runs/37801912044)
failed exactly the original false parameter's settled B-focus assertion at
`WorkspaceComposerDockTests.swift:65`, with key window and attachment both true.
Swift ran 987 tests / 158 suites with one issue; 20 XCTest, all 61 Phone UI
tests (the same expected skip), iPad 1/1 and hygiene passed. There was one
Swift test-run start and no host restart. This was a test failure, not a job
deadline, and the failed xcresult is archived (249,057,562 bytes, SHA-256
`58c07ebe9b7e7d3a31526dc167cf18b1440c03e5727f9d2e68dc385ca003187e`).
Both Phone jobs still logged three previously disclosed SQLite teardown warnings.

Both the passing and failing original false cases logged a keyboard-queue
timeout with no stack and a later generic `[Client] XPC connection interrupted`.
The generic Client line does not identify the connection or service, so it
cannot be equated with the decoded KeyboardManagement context from the older
failure. These messages alone do not determine whether focus assertions fail.

The next temporary diagnostic selects the unchanged original function on three
predeclared fresh runners. A passive log watcher starts external native sampling
only after the keyboard-queue timeout is actually observed, extracting and
checking the app PID from that fault line. There is no sampling before the
fault, no keyboard warmup, and no changed app behavior or assertion. All three
outcomes must be retained; this is not a retry-until-green gate. Missing triggers
or failed sampling are explicitly reported as missing stack evidence. The
temporary workflow must be removed before a later acceptance candidate.


## Fault-triggered capture result and output-latency correction

Run `37810046511` on `97368fec89d10e5844fc3f1dfdea55dae5b72445`
completed all three predefined samples. The original function and both arguments
passed in each sample; none is a reproduced settled-focus failure. Sample 2 had
no keyboard-queue timeout and correctly reported no trigger. Samples 1 and 3
observed the timeout but failed stack capture: `/usr/bin/sample` returned 255
because the application process had already exited after its selected test.
The test exit was 0 and watcher exit was 1 in both jobs. These are diagnostic
failures, not passing stack evidence and not product-test failures.

The fault timestamp versus watcher timestamp shows delays of 1.608 seconds
(sample 1) and 2.646 seconds (sample 3) through the xcodebuild output path.
All three logs and xcresults were downloaded and verified against artifact
size, SHA-256 and ZIP CRC. No sample report was produced in the two failed
captures. The clean-source failure in `37801912044` remains unresolved.

The next bounded diagnostic addresses that measured capture limitation. It
reads the same fault directly from the simulator's native log stream rather
than xcodebuild output, retaining complete lines and the stream's stderr.
It runs the unchanged normal unit-test target (including the original focus
function), with two predefined fresh runners. The broader unit suite retains
the real test-host lifecycle of the failing full-CI run and gives an external
sampler time to finish; it adds no post-test hold, application hook, readiness
wait, process suspension, or new assertion. Production code, tests, project,
configuration and normal CI remain byte-identical to `19423a4`. Stack capture
still starts only after a fault; any scheduling effect after that point remains
a limitation. This temporary diagnostic is not an acceptance gate.

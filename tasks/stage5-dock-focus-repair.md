# Stage 5 Dock focus repair — 2026-10-08

This record describes a reproduced production focus bug. It does not close
Stage 5, the original intermittent PR failure, or physical-device acceptance.

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
alone is not used as an execution guarantee. The cold/related result and final
complete-CI gate are still pending at this record's current checkpoint.

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

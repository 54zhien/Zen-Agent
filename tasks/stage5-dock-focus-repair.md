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

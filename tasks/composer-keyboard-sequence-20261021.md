# Sequential keyboard and menu handoff — 2026-10-21

Owner approved research recommendation: real system keyboard descent, then app-side Liquid Glass menu ascent. Closing descends the panel and restores the same editor's keyboard. Keep Composer expansion, Split divider position and input-region reservation through the whole sequence. Preserve 17.1 corners, five rows, icons and submenus. Compile/package only; do not run tests.

## Plan and ownership

1. ComposerKeyboardMenuSession owns phases, native resign/become requests, completion notifications, cancellation and the shared reserved window top. Timeout is cancellation only. Reserve before resign; keep reservation until the restored keyboard completes.
2. ComposerKeyboardMenuPresenter owns only the app-window panel and interruptible slide animations. No replacement inputView, keyboard snapshot, extra UIWindow or system-private hierarchy access.
3. ComposerHostView retains the same UITextView and logical Editing state during temporary native focus loss. While reserved, switch from the moving native keyboard constraint to an app-owned fixed anchor. Suppression/detachment/explicit blur cancel the session.
4. Workspace caps its viewport at the same reserved top BEFORE computing Split geometry. Single Pane caps its viewport too. Use the remaining intersection once rather than adding keyboard and menu heights. Native keyboard avoidance continues outside the reserved handoff.
5. Review statically, compile/package on macOS CI, download and verify the frozen application source and artifact checksum. No tests or simulator probes.

## Rulings

- Same editor identity does not imply uninterrupted first responder. Native marked-text completion is reported; no fabricated IME state restoration.
- Rapid close during native descent changes destination to keyboard but waits for descent completion. Closing during panel ascent continues from its current animation position. Duplicated close requests are coalesced.
- Background, window size/attachment changes and Workspace suppression cancel; no delayed keyboard resurrection. A missing native completion after 3 seconds releases the session as failure, never opens a panel using a guessed duration.
- The current branch is the existing owner-scoped unmerged Composer branch. Unrelated deep-reading-native-trace.txt remains untouched.
- User's explicit no-test instruction overrides test execution steps in the execution skill. Build evidence and device acceptance remain distinct.

## Progress

Implementation written; static review and macOS package result pending. Blueprint amendment `ea2079ab6ac61dd0c145a0773f5c7adb491454ed` follows the approved current request and supersedes the prior retained-inputView ruling.

Static review found a restoration focus-loss path that otherwise retained its reservation until the watchdog. Native didEndEditing now tells the session to cancel immediately when restoration was in progress; expected didEnd during initial keyboard descent still retains Editing. No tests were run.

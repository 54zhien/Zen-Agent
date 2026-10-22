# Input-first Sidebar dismissal and animated sheet exit — 2026-10-21

Owner reports Sidebar remains draggable with keyboard/medium sheet raised and blank conversation taps remove the sheet instantly. Blueprint 899c821. First leading-edge horizontal swipe consumes input dismissal; only a later swipe opens Sidebar. Blank-area dismissal must animate the sheet down. Continue compile/package only, no tests.

Observed causes: WorkspaceSidebarEligibility deliberately allows stable editing; WorkspaceSurfaceView only ends editing after navigation.isOpen commits. Custom sheet is not a native responder, so window.endEditing cannot dismiss it. ComposerHostView.requestFocus(false) explicitly asked for nonanimated close, and ComposerKeyboardMenuSession.close(false, ...) always finished immediately regardless of animation flag.

Ownership: new ComposerSidebarInputDismissal owns a window-level pan for the attached Composer. Admission requires its own visible native keyboard/session/detail, a foreground window and a touch in the leading 24pt edge strip; only outward horizontal opening motion begins. It takes failure priority over content/Sidebar pans, consuming the entire swipe rather than starting navigation after input disappears. Workspace's broad edge-priority rule yields to its marker recognizer. Detachment removes the recognizer; inactive Composer instances do not admit input. Ordinary taps, vertical scrolling and rail drags away from the edge remain outside this path.

ComposerHostView routes the gesture to existing input owners, cancels pending overlay-focus restoration and resigns its editor. Session non-restoring animated close retains the reservation until descent completion; repeated closes do not interrupt it, while nonanimated lifecycle teardown still finishes immediately. Ending-input intent overrides a pending keyboard restoration. Detail presenters can descend without revealing their parent; normal detail close/return remains available. Blank-background requestFocus(false) requests animated close. Existing keyboard-free Sidebar behavior, interaction/animation settings and haptics are preserved.

Production scope: ComposerSidebarInputDismissal (new), ComposerHostView, ComposerKeyboardMenuSession, ComposerKeyboardMenuPresenter, ComposerMenuDetailPresenter, ComposerActionMenuPresenter, WorkspaceSidebarInteraction. XcodeGen already includes App recursively. Unrelated deep-reading-native-trace.txt excluded. No tests or main merge. Physical-device gesture/animation acceptance remains pending.

Owner follow-up: SidebarRailView new-conversation symbol changes from bubble to the requested SF message, with sizing/style/action untouched (Blueprint bec8ccf).

Gesture dependency direction was checked against Apple's official UIKit example (https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/TransitionGuide/AppearanceCustomization.html): preferred recognizer returns true from shouldBeRequiredToFailBy so the other recognizer waits. A preliminary review interpretation was withdrawn after comparing that example; existing broad Sidebar priority explicitly excludes the input-dismiss marker to avoid a cycle.

## Build and package receipt

Static review completed without remaining actionable findings. No tests were run, as requested.

- Application source: d902b5334479df54a218fdd94564be9428d00bb6.
- Packaging source: f9d73608e87a28d829db00ff9f6f5d307fd0fd22.
- macOS CI: https://github.com/54zhien/Zen-Agent/actions/runs/39602214410 — successful, package job 3m12s; XcodeGen and real unsigned device build passed (Xcode 26.6).
- Downloaded IPA version: 41.1; bundle com.zhien.zen. Local metadata and SHA-256 match the uploaded provenance.
- IPA: C:/Users/Azusa/Documents/Codex/artifacts/2026-10-21-sidebar-input-dismissal/ZenAgent-Composer-device-ipa-41-1/ZenAgent-Composer-41-1.ipa.
- SHA-256: 3c6e82bf2251a1cbe4b30c93ea8471b9065410f096e7d499a774e86ddc866b26.

This is compilation/package evidence only. Physical-device gesture and exit-animation acceptance remains pending; no main merge.

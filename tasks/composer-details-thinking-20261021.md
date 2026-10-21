# Composer bottom details and thinking control — 2026-10-21

## User-approved scope

Current branch is unmerged Composer work, base 06431e9 / package 20.1. Follow the new screenshots and video: lower-left concentric primary menu, all former secondary menus replaced by bottom details, return to the retained primary menu on detail dismissal, vertical left thinking control with right label crossfade and bottom blur, new model/plug/file artwork, continuous remainder arc and highest supported effort endpoint. No tests; compile and package. Unrelated deep-reading-native-trace.txt is excluded.

Blueprint intent: 919f3fe (Design/Zen Agent Conversation UI 与 Composer.md); the latest request supersedes older requirements to preserve secondary menu layout.

## Boundaries and cancellation

- ComposerActionMenuView is now primary rows only. ComposerMenuDetailPresenter/View owns one shared bottom detail path from either primary presenter. Detail dismissal returns to the retained parent. Model choice commits then returns; thinking commits discrete supported values while remaining open. Unsupported features have truthful information sheets, no fake attachment/plugin operations.
- ComposerThinkingControl owns continuous drag preview and capability-indexed commits. Model defaults remain available. Three/four/six supported choices use the same control. Future alignment settings are out of scope.
- Primary floating animation duration, damping, source icon handoff and collapse remain unchanged. Equal 8pt left/bottom insets plus R-8 align the lower-left arc center.
- Detail overlay is inside the current app window, no new UIWindow or system keyboard inspection. Background/size/detachment cleanup remains owned by the parent session.

## Keyboard diagnosis and change

User video sampled at 10fps shows keyboard descent, an empty reserved region, then keyboard return without menu appearance. No on-device event log was supplied, so the triggering callback is not proved by video alone.

The old textViewShouldBeginEditing combined a UIKit eligibility query with keyboardMenu.close(), setting returnsToKeyboard during descent. This is a real reentrant intent hazard matching the symptom. It is now side-effect free, and canBecomeFirstResponder refuses new native focus while the menu owns input. Explicit editor touch/accessibility activation and plus remain restoration sources. Existing responder eligibility remains true until explicit resign.

The didHide handler accepts the owned willHide/didHide sequence and waits one main-actor scheduling turn for resignation callbacks; it no longer rejects a completion based on third-party frame payload. Early willShow is not itself a cancellation during descent. The watchdog only cancels; it does not fake completion. OSLog records phases and responder result without draft content. Real-device confirmation remains required.

## Verification / delivery

Pending static review and macOS XcodeGen/device build. No test suites or simulator probes run.

Static review identified and corrected external responder takeover during descent, landscape concentric inset consistency, and short-height/large-type scrolling. Floating details now derive height from the current window, not stale keyboard history. Final macOS build pending.

Build 39540033359 failed with ambiguous selector dismissSheet (zero-argument handler vs animated: method). Renamed the UI target to closeTapped and made Swift closure calls explicit. The original failed run is preserved; corrected source will receive a new build.

## Final build receipt

- Application source: `0323234101f3274a8baed0df661110b784e03591`; packaging SHA: `abd0ae65438daade5fb8ae4b3368f31185cdd18d`.
- Run https://github.com/54zhien/Zen-Agent/actions/runs/39540332157 succeeded: XcodeGen generation, Xcode 26.6 generic iOS device build, unsigned IPA packaging and upload. No test suites or simulator probes were run.
- The first run 39540033359 failed at the new close selector; retained as failed provenance. The fix used a new commit and new run, not an unchanged retry.
- Downloaded version 22.1, arm64, iOS 26.0+, unsigned Debug/System Sans. BUILD-INFO source and Info.plist ID/version matched; SHA256SUMS matched local SHA-256 `310066e36cd194cfa4170ff9ff9caa3c2a3a234114e819dc5e11b8c39acc06fb`.
- Final static review found no remaining Critical/Important issues. That and the build do not prove device keyboard behavior, blur appearance or gesture feel; those remain device acceptance items. No main merge performed.

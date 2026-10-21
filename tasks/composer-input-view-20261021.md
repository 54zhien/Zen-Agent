# Composer inputView switching — 2026-10-21

Owner approved the discussed plan: keep the same editor as first responder, replace the system keyboard with a custom inputView, restore the keyboard on menu close, match screen-concentric corners and spread five larger icon rows across the panel. Build and package without running tests.

Blueprint ruling: `3157898f6f5aa6e200aa0e0e0c40013ed202dc37` on the existing unmerged design branch. This supersedes the old close-with-keyboard-hidden behavior.

Implementation boundaries:
- ComposerHostView owns the editor.inputView assignment and reloadInputViews. No resign/become cycle during user menu switching; text and selection remain on the same UITextView.
- ComposerKeyboardMenuPresenter owns a self-sizing UIInputView with the measured occupied keyboard height and native Liquid Glass/menu hierarchy. UIKit owns its attachment and avoidance, replacing the window overlay and duplicate menuTop reservation.
- Close/selection/editor activation restores the system input view while focused. Actual blur, suppressed input, detachment and background clear the custom view and end the input session. Rotation releases the old-height view back to the system keyboard.
- Geometry uses the existing public WindowCornerGeometry resolver and a 6pt concentric inset. Circle diameter is 44pt (scaled), symbols 25pt; first/last centers align with the rounded panel when space permits, middle rows distribute evenly. Dynamic Type/short views retain scrolling.
- Updated historical UI assertions for the new close-return behavior and custom input AX semantics; they are not executed or claimed passing.

Ruling: prioritize the approved direct inputView replacement. Apple documents reloadInputViews as an immediate replacement, not an animated keyboard descent. Do not claim a system slide animation or physical-device stability from compile-only evidence.

References: https://developer.apple.com/documentation/uikit/uiresponder/reloadinputviews() ; https://developer.apple.com/documentation/uikit/uiinputview/allowsselfsizing

Validation: pending device build and artifact receipt. No test suites or visual simulator probes will run. Prior keyboard-overlay test success does not verify this new implementation.

Read-only review found that marked input could retain the custom view during Workspace suppression. The scoped correction closes an installed custom input view even in that case, lets UIKit finish the same text view, and reports final native text/selection before focus loss. Ordinary focus requests still preserve the existing IME guard. No tests ran.

## Package receipt

- Application source: `782d3e6b41fd35c223f49f7b94c7923f895c12f3`; packaging commit: `8cc0b36cb31074262dbc56f0fe9fc7c2adb12399`.
- Final build/package run: https://github.com/54zhien/Zen-Agent/actions/runs/39530748460 — success; XcodeGen generation and unsigned generic iOS device build completed with Xcode 26.6.
- Artifact: `ZenAgent-Composer-17-1.ipa`, CFBundleVersion `17.1`, unsigned Debug, arm64, iOS 26.0+.
- Downloaded IPA SHA-256: `4fcd7f4a647c355d8cfd625a14193f7d3b812e36284a7e3247a4630e08e5687f`; checksum, bundle version/id and recorded application source matched.
- Earlier inputView build 39530433839 also succeeded; final package includes the later marked-input cleanup. Narrow read-only review found no remaining blocker in that cleanup path.
- No unit/UI tests or simulator visual probes ran. Device switching, corner appearance and Split stability remain physical-device acceptance items. No main merge performed.

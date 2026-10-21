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

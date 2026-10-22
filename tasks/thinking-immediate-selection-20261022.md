# Immediate Thinking selection feedback — 2026-10-22

Owner rejects the 45.1 feel and explicitly selects: tick immediately whenever dragging enters a different detent, remove endpoint soft impacts. Preserve all other interactions and animations; compile/package only, no tests. Blueprint d9e7ac2. Base 0c2fa25 / delivered package 45.1.

## Change and ownership

ComposerThinkingControl seeds the nearest detent quietly when a thumb drag starts, compares each new clamped nearest index, and emits the existing system selectionChanged feedback only when that index changes. Returning to a prior detent also ticks. The final drag sample is processed normally; committed drag settlement emits no duplicate. The model selection and request state still change at the original completion point. Direct detent taps, accessibility and the default control keep their existing commit-path feedback and timing. Cancel/model switch/suspension/unmount clear the tracking index through the original cancellation path.

Delete the soft generator/moment and its overscroll callback. Restore ComposerThinkingTrack exactly from the retained 44.1 source tag, removing only the 45.1 haptic-specific raw projection plumbing. Artwork, hit targets, curve, thumb clamp, spring, endpoint pulse, label and icon animations are unchanged. The system generator keeps the current Thinking-page visibility and foreground gates, with no new asynchronous queue.

## Rollback

Existing source tag rollback/thinking-hum-44-1-20261022 -> eb39a65d98116fbd53dccd6ba43cd9e685e8151d is retained unchanged. Original verified 800ms hum IPA remains at C:/Users/Azusa/Documents/Codex/artifacts/2026-10-22-thinking-system-haptics/rollback-hum-44-1/ZenAgent-Composer-44-1.ipa, SHA-256 1e0d08c426b2ffd7bffd045bd248fa43151fffbd7da4a624237ce5e19ed183f2. No runtime fallback mode added.

## Verification

Read-only review and real optimized macOS build pending. No tests, no main merge, no edits to the primary checkout's unrelated Sidebar AX work. Actual haptic feel remains for device comparison.

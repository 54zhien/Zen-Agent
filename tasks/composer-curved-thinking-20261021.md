# Composer curved thinking control and menu return — 2026-10-21

User approved redesigned model/plugin/file artwork, an inset gauge needle with settling motion, a black horizontal curved effort control, and animated return to either primary menu. Blueprint c50ca87 supersedes the earlier vertical placement/crossfade design. Preserve primary plus expand/collapse and detail entry. Build/package only; no tests.

Ownership: shared symbol draws neural-network nodes, a tangent-continuous open plug cord and a shorter SF paperclip. The gauge interpolates one progress value for both arc and needle through an underdamped spring. ComposerThinkingControl owns preview/commit cancellation; ComposerThinkingTrack only draws the curved rail, progress and thumb. Drag release snaps to the nearest supported effort; only spring removal commits and changes the label. Default reset and accessibility use the same path. New drag, model/capability changes, departure or sheet dismissal invalidate stale completions. Model capability/request semantics are preserved.

The detail presenter now offers its actual exit animator to the retained parent. Both parent variants prepare invisible material/content before unhiding, then join the same 0.32-second exit animation. Parent hit testing/AX stays blocked until exit completes. Cancellation stops the shared animator; owner dismissal normalizes retained material/content before its existing close. Reduce Motion restores directly. No keyboard session changes.

Apple animation references: https://developer.apple.com/documentation/swiftui/withanimation(_:completioncriteria:_:completion:) and https://developer.apple.com/documentation/swiftui/animationcompletioncriteria/removed. Animation completion is used rather than delayed timers.

Local diff/whitespace checks and independent read-only review complete; no blocking findings. No tests run. macOS build/package receipt pending. Runtime appearance, spring feel and third-party keyboard/device acceptance are not established by compilation. Unrelated deep-reading-native-trace.txt excluded.


## Initial build failure and correction

Run https://github.com/54zhien/Zen-Agent/actions/runs/39549256524 failed at Swift module emission: the two Canvas views inherited MainActor from View while Animatable requires nonisolated animatableData. Mark only their plain Double interpolation storage and accessor nonisolated; rendering and presentation state remain actor-isolated. No unchecked conformance or concurrency suppression. Rebuild uses a new source commit, preserving the failed run.


## Build and delivery receipt

Application source a53f9429e1add0033a73f89c0dc4053f0517d11f; packaging 7bb8f69a4c1270b8e7ce695dfc98fa2905d950a3. Run https://github.com/54zhien/Zen-Agent/actions/runs/39549512438 succeeded: XcodeGen generation, Xcode 26.6 arm64 device build and unsigned IPA packaging. No tests run.

Downloaded version 25.1; Info.plist bundle ID/version and BUILD-INFO source matched. SHA256SUMS matched local SHA-256 d2b6d2a34744540986ad6cac9e97351af0be8b6bea538f6a56c4ee0bad0c2323. Device appearance and animation acceptance remain pending; compilation does not establish them. No main merge.

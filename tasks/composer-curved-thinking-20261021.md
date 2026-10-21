# Composer curved thinking control and menu return — 2026-10-21

User approved redesigned model/plugin/file artwork, an inset gauge needle with settling motion, a black horizontal curved effort control, and animated return to either primary menu. Blueprint c50ca87 supersedes the earlier vertical placement/crossfade design. Preserve primary plus expand/collapse and detail entry. Build/package only; no tests.

Ownership: shared symbol draws neural-network nodes, a tangent-continuous open plug cord and a shorter SF paperclip. The gauge interpolates one progress value for both arc and needle through an underdamped spring. ComposerThinkingControl owns preview/commit cancellation; ComposerThinkingTrack only draws the curved rail, progress and thumb. Drag release snaps to the nearest supported effort; only spring removal commits and changes the label. Default reset and accessibility use the same path. New drag, model/capability changes, departure or sheet dismissal invalidate stale completions. Model capability/request semantics are preserved.

The detail presenter now offers its actual exit animator to the retained parent. Both parent variants prepare invisible material/content before unhiding, then join the same 0.32-second exit animation. Parent hit testing/AX stays blocked until exit completes. Cancellation stops the shared animator; owner dismissal normalizes retained material/content before its existing close. Reduce Motion restores directly. No keyboard session changes.

Apple animation references: https://developer.apple.com/documentation/swiftui/withanimation(_:completioncriteria:_:completion:) and https://developer.apple.com/documentation/swiftui/animationcompletioncriteria/removed. Animation completion is used rather than delayed timers.

Local diff/whitespace checks and independent read-only review complete; no blocking findings. No tests run. macOS build/package receipt pending. Runtime appearance, spring feel and third-party keyboard/device acceptance are not established by compilation. Unrelated deep-reading-native-trace.txt excluded.

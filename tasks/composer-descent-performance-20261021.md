# Composer descent performance — 2026-10-21

Owner approves compiler optimization and reduced repeated decoration work only. Blueprint 6d9b054. Preserve every animation duration, curve, interaction, material and sequential keyboard/menu handoff. Build/package only; no tests.

- Opt-in Config/DevicePackage.xcconfig enables Swift -O / wholemodule and C optimization. Packaging retains Debug, DEBUG and ZEN_DEVICE_TEST; ordinary developer configs are unchanged.
- Session publishes only descent begin/end synchronously. Top-edge decorations in that window keep their Gaussian image and defer new captures until session completion or cancellation. Identity tokens permit independent concurrent owners; detachment clears them. In-flight results cannot replace the retained strip during descent. Existing resize/navigation gates remain independent.
- Bottom fade resolves the current dynamic background but only regenerates colors when it changes; unchanged geometry/visibility and top-edge mask bounds no longer write layer properties.

No actual device profiling was performed. These are reduced source-level costs, not a measured FPS improvement. Static review and macOS build pending; no main merge. Exclude unrelated deep-reading-native-trace.txt.

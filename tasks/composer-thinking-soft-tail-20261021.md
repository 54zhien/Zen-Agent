# Longer, softer Thinking resonance — 2026-10-21

Owner accepts the 34.1 continuous hum direction and requests a longer overall duration and tail, gentler strength and softer onset/decay. Blueprint bd9ab17. Build/package only, no tests. All interactions and animations must remain unchanged.

Only production changes are constants in ThinkingSelectionHaptics.pattern(): duration 140->240ms, base intensity .90->.72, sharpness .25->.18. Envelope (milliseconds/value): 0/0, 12/.08, 26/.40, 40/.80, 55/1, 75/.98, 100/.87, 130/.67, 160/.42, 190/.20, 215/.065, 235/.005, 240/0. Extra onset/tail points soften the change in slope, and the final zero still coincides with event end. These are device-calibration parameters, not measured physical output.

No changes to UI, animation, trigger sites, commit timing, haptic engine prewarm, interruption, stale callback handling, overlap replacement or fallback. Unrelated deep-reading-native-trace.txt excluded. Local diff check clean; no tests run. Actual compilation and physical-device acceptance pending; no main merge.

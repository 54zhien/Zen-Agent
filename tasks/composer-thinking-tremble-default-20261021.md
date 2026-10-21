# Gentle Thinking tremble and immediate default feedback — 2026-10-21

Owner requests a longer/weaker hum with a light tremble at onset and tail, plus immediate selection feedback and softer capsule motion for Use Model Default. Blueprint 73cec91. Build/package only; no tests.

ThinkingSelectionHaptics alone owns the waveform: 240->400ms, intensity .72->.40, sharpness .18->.12. Sixteen control points add low-amplitude fluctuations at onset and tail, with zero intensity at both event boundaries. The thinking-only soft impact fallback is reduced .85->.40. Prewarming, lifecycle, interruption handling, overlap replacement and trigger sites remain unchanged. These parameters need physical-device calibration; no claim of measured physical strength.

Default button delay came from deriving its appearance only from the committed setting, which changes after rail settling completes. Its appearance now follows the accepted pending choice during settling and falls back to the committed setting when canceled. Drag previews do not choose default. Actual request-setting commit, label timing, slider and gauge animations are unchanged. Stable circle identity with animated width/spacing/opacity replaces insertion/removal; capsule spring is .46/.80 and press spring .30/.80. Reduce Motion remains respected.

Scope: three production files, README baseline and this record. Unrelated deep-reading-native-trace.txt excluded. Compilation and device acceptance pending. No tests or main merge.

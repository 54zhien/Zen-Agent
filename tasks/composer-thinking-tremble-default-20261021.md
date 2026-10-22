# Gentle Thinking tremble and immediate default feedback — 2026-10-21

Owner requests a longer/weaker hum with a light tremble at onset and tail, plus immediate selection feedback and softer capsule motion for Use Model Default. Blueprint 73cec91. Build/package only; no tests.

ThinkingSelectionHaptics alone owns the waveform: 240->400ms, intensity .72->.40, sharpness .18->.12. Sixteen control points add low-amplitude fluctuations at onset and tail, with zero intensity at both event boundaries. The thinking-only soft impact fallback is reduced .85->.40. Prewarming, lifecycle, interruption handling, overlap replacement and trigger sites remain unchanged. These parameters need physical-device calibration; no claim of measured physical strength.

Default button delay came from deriving its appearance only from the committed setting, which changes after rail settling completes. Its appearance now follows the accepted pending choice during settling and falls back to the committed setting when canceled. Drag previews do not choose default. Actual request-setting commit, label timing, slider and gauge animations are unchanged. Stable circle identity with animated width/spacing/opacity replaces insertion/removal; capsule spring is .46/.80 and press spring .30/.80. Reduce Motion remains respected.

Scope: three production files, README baseline and this record. Unrelated deep-reading-native-trace.txt excluded. Compilation and device acceptance pending. No tests or main merge.

## Build and delivery receipt

Read-only review found no blocking issue: pending default feedback, cancellation, repeated taps and unchanged commit/slider logic inspected; curve times strictly increase and all values are in range. Application source 343e95fe125448371a998717b7054fb31138fae1; packaging d550de740a964955204c34e2b88b1547ba24f990. Run https://github.com/54zhien/Zen-Agent/actions/runs/39590408566 passed frozen-source comparison, XcodeGen, Xcode 26.6 device compilation and unsigned IPA packaging in 2m35s. No tests run.

Downloaded 36.1 and verified source provenance, bundle identity/version and SHA256SUMS. SHA256: 83ac5051c15e2a38a41708be2fd5d8e486c3f6de81d2e4e8aca203e3e9d58e68. Artifact: C:/Users/Azusa/Documents/Codex/artifacts/2026-10-21-thinking-tremble-default/ZenAgent-Composer-device-ipa-36-1/ZenAgent-Composer-36-1.ipa. Haptic and animation feel remain pending owner physical-device acceptance. No main merge.

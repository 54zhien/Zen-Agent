# Longer rising Thinking resonance — 2026-10-21

Owner requests longer duration, a more drawn-out onset and moderately stronger force after package 36.1. Blueprint 798de08. Build/package only, no tests.

The sole production change is waveform constants in ThinkingSelectionHaptics.pattern(): duration .40->.56 seconds, base intensity .40->.52, peak arrival .155->.250 seconds. The same sixteen envelope amplitudes preserve onset/tail ripples and zero endpoints; their times are stretched to extend the onset and decay. Sharpness remains .12. These are tuning parameters, not measured physical output.

Fallback, engine lifecycle/prewarming, interruption/replacement, trigger sites, all UI interactions and animations (including immediate default-pill feedback) remain unchanged. No main merge. Unrelated deep-reading-native-trace.txt excluded. Static review and actual build receipt follow; no tests are run and physical-device acceptance remains pending.

## Build and delivery receipt

Read-only review found no actionable issue; all sixteen times strictly increase, values are in range, and final zero matches event end. Application source db64818e94edafc92d6f24b2387a697835060889; packaging 9d821755f4f461f37d2be590a4c1c2f9545855b4. Run https://github.com/54zhien/Zen-Agent/actions/runs/39592163920 passed frozen-source comparison, XcodeGen, Xcode 26.6 device compilation and unsigned IPA packaging in 2m49s. No tests run.

Downloaded 37.1 and verified source provenance, bundle identity/version and SHA256SUMS. SHA256: f6c3bdd6324091ddeea8570d25c82d7cda3cc10733cdb1c88203b23a973c7e6c. Artifact: C:/Users/Azusa/Documents/Codex/artifacts/2026-10-21-thinking-long-onset/ZenAgent-Composer-device-ipa-37-1/ZenAgent-Composer-37-1.ipa. Physical-device acceptance pending. During packaging owner asked about whole-device vibration and envelopes; explained a sustained middle plateau as a possible later direction, but did not include that additional change in this package. No main merge.

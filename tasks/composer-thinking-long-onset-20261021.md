# Longer rising Thinking resonance — 2026-10-21

Owner requests longer duration, a more drawn-out onset and moderately stronger force after package 36.1. Blueprint 798de08. Build/package only, no tests.

The sole production change is waveform constants in ThinkingSelectionHaptics.pattern(): duration .40->.56 seconds, base intensity .40->.52, peak arrival .155->.250 seconds. The same sixteen envelope amplitudes preserve onset/tail ripples and zero endpoints; their times are stretched to extend the onset and decay. Sharpness remains .12. These are tuning parameters, not measured physical output.

Fallback, engine lifecycle/prewarming, interruption/replacement, trigger sites, all UI interactions and animations (including immediate default-pill feedback) remain unchanged. No main merge. Unrelated deep-reading-native-trace.txt excluded. Static review and actual build receipt follow; no tests are run and physical-device acceptance remains pending.

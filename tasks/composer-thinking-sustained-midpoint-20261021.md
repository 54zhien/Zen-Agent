# Sustained Thinking hum and midpoint title — 2026-10-21

Owner approves drawn-out onset, stable sustained middle and soft release, with tremble only at the ends; requests the effort title slightly higher, midway between the lower rail arc at horizontal center and model name. Blueprint 6397aa2. Preserve other interactions/animations. Compile and package, no tests.

ThinkingSelectionHaptics.pattern() changes to an 800ms continuous event: 250ms rise, a constant envelope value of 1 from 250 to 500ms, and 300ms release ending at zero. Peak base intensity .52 and sharpness .12 remain; gentle envelope ripples occur only before and after the steady plateau. Sixteen control points. Fallback, lifecycle, prewarming, interruption, replacement and trigger sites are unchanged. Sustained whole-device feel is an experiential goal, not a claim of uniform mechanical vibration.

ComposerThinkingControl preserves the title's original fixed-height layout reservation, rail/model/default-pill layout and spacing. Rail and model bounds are resolved with anchor preferences in one layout pass, without geometry state updates. The visible title is centered between the shared rail geometry's inner arc midpoint and the model frame's upper edge. Its existing directional transition view/font/committed-value semantics remain unchanged. Overlay hit testing is disabled. No modifications to gestures, snapping, gauge, default capsule, settings commit timing or menu transitions.

Scope: two production files, README and this record. Unrelated deep-reading-native-trace.txt excluded. No tests or main merge. Build and physical-device acceptance pending.

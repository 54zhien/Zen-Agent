# Resonant Thinking selection feedback — 2026-10-21

Owner rejects the near-imperceptible single light impact and approves a clearly perceptible continuous hum with a soft onset and lingering decay. Blueprint b6806f0. Only change feedback rendering; preserve existing trigger sites, duplicate suppression, interaction, request/selection timing and all UI animation. Build/package only, no tests.

ThinkingSelectionHaptics owns a separate Core Haptics engine and current player. A 140ms hapticContinuous event uses intensity 0.90/sharpness 0.25. Explicit intensity control points are 0ms/0, 18ms/1, 50ms/.95, 85ms/.60, 115ms/.25, 140ms/0. These are calibration choices, not measured physical strength. No audio events, playsHapticsOnly enabled, engine kept ready only while the Thinking page is visible; dismissed/inactive pages stop it. Hardware unsupported or a thrown playback failure falls back to a soft UIKit impact at .85; fallback is not represented as the custom hum.

New selection stops the previous player before starting a fresh one, avoiding stacked tails. Thinking page appearance/resume asynchronously warms the engine; dismissal/inactivity stops it. The haptic helper alone owns engine/readiness/startup state on the main actor. UUID generations reject callbacks from retired engines. Reset retires stale resources and asynchronously warms a replacement; stoppage leaves restart for the next activation/play, avoiding interruption retry loops. Unready playback gives immediate fallback rather than queueing a stale hum. No synchronous engine.start() occurs on the interaction thread. No delayed tasks schedule playback; inactive requests are ignored. Detach the engine before its asynchronous stop, preventing a stale stop from affecting rapid foreground selection. No automatic foreground or reset-triggered replay.

Read-only review identified synchronous engine startup as an interaction latency risk; it was replaced with async prewarm. Inspection also confirmed suspensionRevision increments only on suspend, so resume prewarm observes the actual isSuspended flag rather than relying on that revision. Selection/cancellation logic and all animation parameters remain unchanged.

Apple references checked for event/curve duration semantics and engine lifecycle:
- https://developer.apple.com/documentation/corehaptics/chhapticengine
- https://developer.apple.com/documentation/corehaptics/chhapticparametercurve/init(parameterid:controlpoints:relativetime:)
- https://developer.apple.com/documentation/corehaptics/chhapticpattern/init(events:parametercurves:)
- https://developer.apple.com/documentation/corehaptics/representing-haptic-patterns-in-ahap-files

Local diff check clean. No tests run. Actual Xcode compilation and device feel pending. Unrelated deep-reading-native-trace.txt excluded; no main merge.

## Build and delivery receipt

Follow-up read-only review found the startup issue resolved and no new blocking issue. Application source 0c00b53adc2071c6c81c1f34714e8de90abfa897; packaging fc52b0f9bf27ea2d5bfd807a34bca1d6c1347646. Run https://github.com/54zhien/Zen-Agent/actions/runs/39586988705 passed frozen-source comparison, XcodeGen, Xcode 26.6 device compilation and unsigned IPA packaging in 1m37s. No tests run.

Downloaded 34.1, verified application source provenance, bundle identity/version and SHA256SUMS. SHA256: d6011ebb7c7ae6b0d75da65bf874013e8b04160c1c1882cc853c5cd2ba18405e. Artifact: C:/Users/Azusa/Documents/Codex/artifacts/2026-10-21-thinking-resonance/ZenAgent-Composer-device-ipa-34-1/ZenAgent-Composer-34-1.ipa. Physical-device haptic acceptance remains pending; compilation does not establish perceived strength or texture. No main merge.

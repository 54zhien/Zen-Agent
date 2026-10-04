# S5-16 Visual reinforcement — implementation and validation record

## Native behavior RED observed before production

Settings FULL closed at remote2d501a6be6a39ee1194a3302c1e5241e23771fb8,
tree437d5de40a08affbb25dd341db8d9dc9e519a3f5,local4025b41. Both complete
runs37236474441/37236477630 and guard37236477646 passed; see S5-15 record.
Branch codex/s5-16-visuals begins from that exact source, stacked on draft PR32.

First publication adds the real existing-API CurrentCardEdgeTests and an actual
Appearance UI regression. The native edge must fit its cropped Surface, remain
one layer through repeated poses and disappear in Full. The UI reaches existing
Settings/Appearance before expecting missing Ink controls; after implementation
it will verify persisted controls, real dark-mode effects and repeated native
Lift/Return preserving Current identity,editor,draft and one Composer.

The fixed-branch visuals-red profile runs the complete unit target and all
Settings UI; actual Pad remains unchanged. Its local scope guard first failed,
then passed12 tests after the fixed mode was added. This local configuration
check is not product behavior RED. Real macOS XcodeGen/build and native behavior
failures must precede production effects. The new Motion policy test draft is
excluded until its actual type exists; missing symbols are not behavior RED.
No renderer/edge production implementation is in that RED publication.

Both RED runs completed XcodeGen and real app/test builds. Push37239980587
ran931 Swift tests/148 suites in99.175s; PR37240008961 in105.126s. Each
recorded exactly2 CurrentCardEdge issues (missing sole layer and required path).
Each also passed20 XCTest and the original3 Settings UI; the new actual
Appearance test failed only because the Ink switch was absent. UI totals4,
one failure,181.685s/150.804s. Actual iPad passed102.855s/110.456s and
guard37240008951 passed. One Swift test-run start, no host restart/retry.
Raw RED logs remain in the external handoff directory.

## First implementation candidate — awaiting macOS result

After the genuine RED, a native opaque canvas owns one root and two radial
gradients. Gesture samples change only bounded reverse displacement/intensity;
they do not restart keyed slow flow. Live scene, Reduce Motion, low power and
thermal policy freezes flow/parallax, keeping static dark Ink. Window detachment
also removes animations. Light mode or disabled Ink uses a static background.
Actual Settings controls persist through the existing Appearance owner.

SurfaceClipView owns one faint Current-only semantic outline above hosted content.
It follows the real visible crop/corner radius, matches Browse crop settlement
with one bounded path animation, clears that work on replacement/cancellation
and hides in Full. No new gesture, Timeline, session, Router or Runtime owner.
Native tests exercise layer identity, real animation keys, window lifecycle,
policy changes, finite bounds, crop replacement and preference reload.
The actual Settings UI exercises enablement/intensity, dark mode, two Lift/Return
cycles and retained editor/identity/draft. Targeted and FULL gates remain OPEN.

## Approved bounded design and device limits

This authorized slice follows the Settings full code gate. Production work began
only after the real native behavior RED above.

Blueprint requires restrained cool-black Ink, independent slow flow, tightly
bounded reverse parallax and a faint Current-only edge fitted to its visible
crop. Preserve native navigation, selected identity, reading ownership and the
approved card stack in both orientations. Light-mode Ink remains off pending
an explicit palette decision.

Use fixed small opaque native layers and keyed reusable animations. No
per-frame SwiftUI timer, accumulating animation loop, full-screen live blur or
unmeasured shader work. Consume existing Browse displacement and actual Surface
geometry; clamp finite reverse displacement to a small range. Reduce Motion
keeps static Ink and removes flow/parallax. Low power, serious/critical thermal
pressure and inactive scene freeze motion under the same observable policy.

The native Current outline follows the actual visible crop, stays above the
opaque content, does not duplicate on historical projections and hides in Full.
Keep bounded layer count through repeated geometry, selection and appearance
updates. Settings enablement/intensity applies through the retained observable
appearance/effect owner.

Publish genuine native visible-edge behavior RED before production changes.
Verify crop fitting, Full removal, layer identity/count, finite saturation,
policy changes mid-gesture and selection/Return preservation; pass full macOS
generation/build/unit/UI/actual Pad gates. Reconcile all stacked PR heads and
records in the whole-stage review handoff. GPU/energy/frame pacing, comfort and
VoiceOver acceptance require the owner's subsequent physical-device pass.

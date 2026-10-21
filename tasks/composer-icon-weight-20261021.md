# Composer icon outlines and optical balance — 2026-10-21

Owner asks to redraw the plugin from the enlarged reference and avoid thick strokes across all icons, balancing perceived size. Blueprint d1f5998. Shared icon-only change; menu geometry, gray circles, accepted transitions, request semantics and lifecycle unchanged. Build/package only, no tests.

Plugin: two separate prongs, rounded plug rear, one open circular cord with a tangent cubic return to the rear. The previous cord changed direction abruptly. All vector symbols use a proportional 1.8/28 stroke rather than 0.085 of their frame; model moves from a fixed point-size ellipse to the same scalable optical grid. Model/photo use comparable extents; narrow upright clip gets a little more height/width; thinking gauge radius is adjusted to match and keeps its existing needle/arc motion. The unsupported-thinking SF fallback uses regular weight.

Inspected an equivalent SVG construction at 3x in light/dark circular backgrounds to compare outline weight and proportions (not an iOS screenshot or runtime test). Actual native rendering remains subject to device acceptance. Local diff check clean; macOS compilation pending. Unrelated deep-reading-native-trace.txt excluded. No main merge.

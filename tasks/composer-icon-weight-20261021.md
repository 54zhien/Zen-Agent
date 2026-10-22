# Composer icon outlines and optical balance — 2026-10-21

Owner asks to redraw the plugin from the enlarged reference and avoid thick strokes across all icons, balancing perceived size. Blueprint d1f5998. Shared icon-only change; menu geometry, gray circles, accepted transitions, request semantics and lifecycle unchanged. Build/package only, no tests.

Plugin: two separate prongs, rounded plug rear, one open circular cord with a tangent cubic return to the rear. The previous cord changed direction abruptly. All vector symbols use a proportional 1.8/28 stroke rather than 0.085 of their frame; model moves from a fixed point-size ellipse to the same scalable optical grid. Model/photo use comparable extents; narrow upright clip gets a little more height/width; thinking gauge radius is adjusted to match and keeps its existing needle/arc motion. The unsupported-thinking SF fallback uses regular weight.

Inspected an equivalent SVG construction at 3x in light/dark circular backgrounds to compare outline weight and proportions (not an iOS screenshot or runtime test). Actual native rendering remains subject to device acceptance. Local diff check clean; macOS compilation pending. Unrelated deep-reading-native-trace.txt excluded. No main merge.

## Build receipt

Source c9f71dc79e4c588f71db01b9cfc393ad7159c130; packaging 2597ec5ad1efd7d6edf5231bcf82654d8780bb11. Run https://github.com/54zhien/Zen-Agent/actions/runs/39561014385 passed XcodeGen and Xcode 26.6 device compilation/package. No tests. Downloaded 28.1, verified bundle version, source provenance and SHA256SUMS: b52e1fe49d979a76dfc6f81d34500f0d35d8194be5a645e87c00aa34b647a124. User then requested thinking layout/interaction and dark handle follow-up; retain these icons in the next package.

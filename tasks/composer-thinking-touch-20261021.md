# Thinking page spacing, thumb touch and endpoints — 2026-10-21

Owner steering while icon package 28.1 downloaded: put default capsule at bottom, model above it, committed effort above that with a real gap below the rail; crossfade changed effort/model labels. Only the thumb can initiate dragging, detent clicks animate selection, blank rail must not teleport. Replace endpoint overshoot/clamped delay with immediate endpoint feedback. Keep the dark Split divider itself; match only its white handle behavior to light mode. Blueprint 25cc5f4. Prior reference icon changes retained. Build/package only, no tests.

Source causes: labels were overlaid inside the rail's rectangular bounds; a rectangular zero-distance gesture projected any location onto the arc; all destinations waited for the same spring removal even when the rendered thumb was already clamped at an endpoint. Dark handle had an extra 1-progress alpha multiplier absent in light.

Implementation: fixed vertical budget with footer capsule aligned to the bottom, adaptive short-height rail/text, identity-based crossfades only on committed values. Interactive thumb follows the actual animated geometry, uses a 3pt drag admission threshold and retains grab offset using unclamped angular projection; stationary taps do not change default semantics. Detent buttons use disjoint local hit circles bounded by neighbor spacing. Blank artwork is not interactive. A second control cannot submit during an admitted drag. Endpoints use 0.22s monotonic ease-out; an already-arrived release commits synchronously, with brief thumb compression rather than invisible spring overshoot. Intermediate detents retain damped snapping. Cancellation, capability/model changes, background revision and late-completion guards retained. Dark-only alpha fade removed; shared handle color transition, divider background/geometry and resize unchanged.

Read-only review identified minimum stack overflow on short keyboards and no-motion thumb taps changing default semantics; both corrected before build. No tests or on-device validation run. Local diff check and macOS build receipt to follow. Unrelated deep-reading-native-trace.txt excluded; no main merge.

## Build and delivery receipt

Final read-only review found no remaining Important/blocking issue after the short-layout, stationary-thumb and neighbor-hit fixes. Source 2b7c764e20086582802825ae9bc4cfcb61388402; packaging 0b6caf4cd096dd50742e354437915c6cc41417f1. Run https://github.com/54zhien/Zen-Agent/actions/runs/39563158185 passed frozen-source comparison, XcodeGen, Xcode 26.6 device compilation and unsigned IPA packaging. No tests.

Downloaded 29.1 and verified bundle identity/version, application source provenance and SHA256SUMS: 450701fff8a4fc4b0ef5d290de71e488e0c3e74ba8d79f7e0ba83954d865e3ce. Includes the previously compiled icon refinement. Visual/touch behavior still needs device acceptance; no main merge.

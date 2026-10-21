# Recessed thinking rail — 2026-10-21

Owner approved a shallow recessed curved slot, thumb reduced to roughly 70% of rail thickness, slightly raised effort label, and fixed optical centering of the thinking gauge. Blueprint bf7dfb3. Preserve all interaction and animation; build/package only, no tests.

Three existing views own the change. The track keeps its analytical circle and hit projection, but draws one closed round-capped slot outline with native inner shadows and a subtle rim; the selected floor leaves a visible slot lip. The thumb has a short contact shadow, with its existing 44pt hit area, drag threshold, grab offset and endpoint motion unchanged. The effort label moves up 1/3/4/8pt according to available height, without changing the layout budget for rail, model name or default button. Gauge placement centers its open-arc bounds and applies a fixed 2%-of-edge optical compensation; needle and arc animation values are unchanged.

No new state, asynchronous work or cancellation paths. Existing animation and selection logic is preserved. Local diff review and read-only reviewer found no actionable issue. An equivalent SVG geometry preview was inspected in light/dark at minimum, middle and maximum; it is artwork review, not native rendering or runtime verification. Native ShapeStyle inner shadow signatures checked against Apple documentation: https://developer.apple.com/documentation/swiftui/shapestyle/shadow(_:)-swift.method

Actual iOS compilation and package receipt pending. No tests run. Unrelated deep-reading-native-trace.txt excluded. No main merge.

import SwiftUI

/// Shared analytical geometry keeps the artwork, detents and hit projection on
/// one circle; the recessed finish does not change the interaction geometry.
struct ComposerThinkingArcGeometry {
    let size: CGSize
    var inset: CGFloat = 30
    private var halfWidth: CGFloat { max(1, (size.width - 2 * inset) / 2) }
    private var rise: CGFloat { min(min(66, halfWidth * 0.62), max(2, size.height - 2 * inset)) }
    private var radius: CGFloat { (halfWidth * halfWidth + rise * rise) / (2 * rise) }
    private var center: CGPoint {
        CGPoint(x: size.width / 2, y: size.height - inset + radius - rise)
    }
    private var halfAngle: Double { asin(Double(halfWidth / radius)) }
    private var startAngle: Double { -.pi / 2 - halfAngle }

    func point(at fraction: Double) -> CGPoint {
        let angle = startAngle + 2 * halfAngle * fraction
        return CGPoint(x: center.x + radius * CGFloat(cos(angle)),
                       y: center.y + radius * CGFloat(sin(angle)))
    }

    func fraction(at point: CGPoint) -> Double {
        min(1, max(0, projectedFraction(at: point)))
    }

    func projectedFraction(at point: CGPoint) -> Double {
        let angle = atan2(Double(point.y - center.y), Double(point.x - center.x))
        return (angle - startAngle) / (2 * halfAngle)
    }

    func path(to fraction: Double) -> Path {
        var path = Path()
        path.addArc(center: center, radius: radius, startAngle: .radians(startAngle),
                    endAngle: .radians(startAngle + 2 * halfAngle * fraction), clockwise: false)
        return path
    }
}

/// One closed outline provides the slot, its rim and the inset progress floor.
/// Round caps are tangent to the circular rail; no overlapping end discs or
/// differently sized outline strokes create a seam at the joins.
private struct ComposerThinkingSlot: Shape {
    var end: Double = 1
    let inset: CGFloat
    let thickness: CGFloat

    func path(in rect: CGRect) -> Path {
        let curve = ComposerThinkingArcGeometry(size: rect.size, inset: inset)
        if end <= 0 {
            let start = curve.point(at: 0)
            return Path(ellipseIn: CGRect(x: start.x - thickness / 2 + rect.minX,
                                         y: start.y - thickness / 2 + rect.minY,
                                         width: thickness, height: thickness))
        }
        return curve.path(to: end)
            .strokedPath(StrokeStyle(lineWidth: thickness, lineCap: .round, lineJoin: .round))
            .offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

private struct ComposerThinkingRecess: View {
    @Environment(\.colorScheme) private var colorScheme
    let fraction: Double
    let inset: CGFloat
    let thickness: CGFloat

    var body: some View {
        let dark = colorScheme == .dark
        let slot = ComposerThinkingSlot(inset: inset, thickness: thickness)
        let lip = min(3, thickness * 0.08)
        let floor = ComposerThinkingSlot(end: fraction, inset: inset, thickness: thickness - 2 * lip)
        let depth = min(2.5, thickness * 0.055)
        ZStack {
            slot.fill((dark ? Color(white: 0.12) : Color(white: 0.90))
                .shadow(.inner(color: .black.opacity(dark ? 0.55 : 0.19), radius: depth, y: depth))
                .shadow(.inner(color: .white.opacity(dark ? 0.07 : 0.70), radius: depth * 0.6, y: -depth * 0.6)))
            floor.fill((dark ? Color(white: 0.62) : Color.black)
                .shadow(.inner(color: .black.opacity(0.18), radius: 1, y: 1)))
            slot.stroke(LinearGradient(colors: [.black.opacity(dark ? 0.25 : 0.06),
                                                 .white.opacity(dark ? 0.13 : 0.85)],
                                       startPoint: .top, endPoint: .bottom), lineWidth: 0.65)
        }
        .allowsHitTesting(false)
    }
}

/// Interpolate geometry once so the thumb follows the curve throughout a snap.
struct ComposerThinkingTrack: View, Animatable {
    @Namespace private var coordinateSpace
    nonisolated var progress: Double
    let count: Int
    let thickness: CGFloat
    let isDragging: Bool
    let endpointPulse: Int
    let enabled: Bool
    let interactionRevision: Int
    let onDragStarted: (Double) -> Void
    let onDrag: (Double) -> Void
    let onDragEnded: (Double) -> Void
    let onDragCancelled: () -> Void
    let onSelect: (Int) -> Void
    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        GeometryReader { geometry in
            let inset = thickness / 2 + 4
            let curve = ComposerThinkingArcGeometry(size: geometry.size, inset: inset)
            let fraction = min(1, max(0, progress))
            let nextPoint = curve.point(at: 1 / Double(max(1, count - 1)))
            let firstPoint = curve.point(at: 0)
            let spacing = hypot(nextPoint.x - firstPoint.x, nextPoint.y - firstPoint.y)
            let hitDiameter = count > 1 ? min(44, max(12, spacing - 2)) : 44
            ZStack(alignment: .topLeading) {
                ComposerThinkingRecess(fraction: fraction, inset: inset, thickness: thickness)
                ForEach(0..<count, id: \.self) { index in
                    let t = Double(index) / Double(max(1, count - 1))
                    Button { onSelect(index) } label: {
                        Circle().fill(t <= fraction ? Color.white.opacity(0.5) : Color.primary.opacity(0.25))
                            .frame(width: 6, height: 6)
                            .frame(width: hitDiameter, height: hitDiameter).contentShape(Circle())
                    }
                    .buttonStyle(.plain).position(curve.point(at: t))
                }
                ComposerThinkingThumb(fraction: fraction, curve: curve,
                    coordinateSpace: coordinateSpace, diameter: min(36, thickness * 0.70),
                    compressed: isDragging && (fraction <= 0 || fraction >= 1),
                    endpointPulse: endpointPulse, enabled: enabled,
                    interactionRevision: interactionRevision,
                    onStarted: onDragStarted, onMove: onDrag,
                    onEnded: onDragEnded, onCancelled: onDragCancelled)
                    .position(curve.point(at: fraction))
            }
            .coordinateSpace(name: coordinateSpace)
            .allowsHitTesting(enabled)
        }
    }
}

/// Local hit geometry moves with the rendered thumb, including during a snap.
/// Retain the finger's grab offset so starting at its edge never teleports it.
private struct ComposerThinkingThumb: View {
    let fraction: Double
    let curve: ComposerThinkingArcGeometry
    let coordinateSpace: Namespace.ID
    let diameter: CGFloat
    let compressed: Bool
    let endpointPulse: Int
    let enabled: Bool
    let interactionRevision: Int
    let onStarted: (Double) -> Void
    let onMove: (Double) -> Void
    let onEnded: (Double) -> Void
    let onCancelled: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var touching = false
    @State private var dragging = false
    @State private var grabOffset = 0.0

    var body: some View {
        Circle().fill(.white)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
            .frame(width: diameter, height: diameter)
            .shadow(color: .black.opacity(0.22), radius: 1, y: 1)
            .scaleEffect(compressed && !reduceMotion ? 0.92 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: compressed)
            .phaseAnimator([1.0, 0.92, 1.0], trigger: endpointPulse) { content, phase in
                content.scaleEffect(reduceMotion ? 1 : phase)
            } animation: { _ in .easeOut(duration: reduceMotion ? 0 : 0.09) }
            .frame(width: 44, height: 44).contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named(coordinateSpace))
                .updating($touching) { _, active, _ in active = true }
                .onChanged { value in
                    guard enabled else { return }
                    if !dragging {
                        dragging = true
                        grabOffset = curve.projectedFraction(at: value.startLocation) - fraction
                        onStarted(fraction)
                    }
                    onMove(project(value.location))
                }
                .onEnded { value in
                    guard dragging else { return }
                    dragging = false
                    if enabled { onEnded(project(value.location)) } else { onCancelled() }
                })
            .onChange(of: touching) { _, active in if !active { cancel() } }
            .onChange(of: enabled) { _, value in if !value { cancel() } }
            .onChange(of: interactionRevision) { _, _ in cancel() }
            .onDisappear { cancel() }
    }

    private func project(_ point: CGPoint) -> Double {
        min(1, max(0, curve.projectedFraction(at: point) - grabOffset))
    }

    private func cancel() {
        guard dragging else { return }
        dragging = false
        onCancelled()
    }
}

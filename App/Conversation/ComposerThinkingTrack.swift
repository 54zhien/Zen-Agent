import SwiftUI

/// Shared analytical geometry keeps the artwork, detents and hit projection on
/// one circle; no line-segment approximation or offscreen blur is involved.
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

private struct ComposerThinkingArc: Shape {
    var end: Double
    var inset: CGFloat = 30
    func path(in rect: CGRect) -> Path {
        ComposerThinkingArcGeometry(size: rect.size, inset: inset).path(to: end)
            .offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

/// Interpolate geometry once so the thumb follows the curve throughout a snap.
struct ComposerThinkingTrack: View, Animatable {
    @Environment(\.colorScheme) private var colorScheme
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
            let fill = colorScheme == .dark ? Color(white: 0.62) : Color.black
            let stroke = StrokeStyle(lineWidth: thickness, lineCap: .round, lineJoin: .round)
            ZStack(alignment: .topLeading) {
                Group {
                    ComposerThinkingArc(end: 1, inset: inset)
                        .stroke(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: thickness + 2, lineCap: .round))
                    ComposerThinkingArc(end: 1, inset: inset).stroke(Color(uiColor: .systemGray5), style: stroke)
                    ComposerThinkingArc(end: fraction, inset: inset).stroke(fill, style: stroke)
                    Circle().fill(fill).frame(width: thickness, height: thickness).position(curve.point(at: 0))
                }.allowsHitTesting(false)
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
                    coordinateSpace: coordinateSpace, diameter: max(14, min(42, thickness - 6)),
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

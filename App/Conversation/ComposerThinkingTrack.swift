import SwiftUI

/// Shared analytical geometry keeps the artwork, detents and hit projection on
/// one circle; no line-segment approximation or offscreen blur is involved.
struct ComposerThinkingArcGeometry {
    let size: CGSize
    private var halfWidth: CGFloat { max(1, (size.width - 60) / 2) }
    private var rise: CGFloat { min(min(66, halfWidth * 0.62), max(12, size.height - 60)) }
    private var radius: CGFloat { (halfWidth * halfWidth + rise * rise) / (2 * rise) }
    private var center: CGPoint {
        CGPoint(x: size.width / 2, y: size.height - 30 + radius - rise)
    }
    private var halfAngle: Double { asin(Double(halfWidth / radius)) }
    private var startAngle: Double { -.pi / 2 - halfAngle }

    func point(at fraction: Double) -> CGPoint {
        let angle = startAngle + 2 * halfAngle * fraction
        return CGPoint(x: center.x + radius * CGFloat(cos(angle)),
                       y: center.y + radius * CGFloat(sin(angle)))
    }

    func fraction(at point: CGPoint) -> Double {
        let angle = atan2(Double(point.y - center.y), Double(point.x - center.x))
        return min(1, max(0, (angle - startAngle) / (2 * halfAngle)))
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
    func path(in rect: CGRect) -> Path {
        ComposerThinkingArcGeometry(size: rect.size).path(to: end)
            .offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

/// Interpolate geometry once so the thumb follows the curve throughout a snap.
struct ComposerThinkingTrack: View, Animatable {
    @Environment(\.colorScheme) private var colorScheme
    nonisolated var progress: Double
    let count: Int
    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        GeometryReader { geometry in
            let curve = ComposerThinkingArcGeometry(size: geometry.size)
            let fraction = min(1, max(0, progress))
            let fill = colorScheme == .dark ? Color(white: 0.62) : Color.black
            let stroke = StrokeStyle(lineWidth: 52, lineCap: .round, lineJoin: .round)
            ZStack(alignment: .topLeading) {
                ComposerThinkingArc(end: 1)
                    .stroke(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 54, lineCap: .round))
                ComposerThinkingArc(end: 1).stroke(Color(uiColor: .systemGray5), style: stroke)
                ComposerThinkingArc(end: fraction).stroke(fill, style: stroke)
                Circle().fill(fill).frame(width: 52, height: 52).position(curve.point(at: 0))
                ForEach(0..<count, id: \.self) { index in
                    let t = Double(index) / Double(max(1, count - 1))
                    Circle().fill(t <= fraction ? Color.white.opacity(0.5) : Color.primary.opacity(0.25))
                        .frame(width: 6, height: 6).position(curve.point(at: t))
                }
                Circle().fill(.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
                    .frame(width: 42, height: 42).position(curve.point(at: fraction))
            }
        }
        .accessibilityHidden(true)
    }
}

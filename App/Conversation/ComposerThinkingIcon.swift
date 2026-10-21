import SwiftUI

extension ThinkingEffort {
    var fraction: Double { Double(Self.allCases.firstIndex(of: self)! + 1) / Double(Self.allCases.count) }

    var title: String {
        switch self {
        case .low: "低"
        case .medium: "中"
        case .high: "高"
        case .xhigh: "极高"
        case .max: "Max"
        case .ultra: "Ultra"
        }
    }
}

/// Arc and needle share the same polar coordinates, including the model's highest supported endpoint.
struct ComposerThinkingIcon: View {
    let level: ThinkingEffort
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var supportedLevels: [ThinkingEffort] = ThinkingEffort.allCases
    private var fraction: Double {
        guard let index = supportedLevels.firstIndex(of: level) else { return level.fraction }
        return Double(index + 1) / Double(supportedLevels.count)
    }

    var body: some View {
        ComposerThinkingGauge(progress: fraction)
            .animation(reduceMotion ? nil : .spring(response: 0.56, dampingFraction: 0.46), value: fraction)
            .accessibilityHidden(true)
    }
}

/// Interpolate the drawing itself so the needle and arc cannot drift apart.
private struct ComposerThinkingGauge: View, Animatable {
    @Environment(\.colorScheme) private var colorScheme
    nonisolated var progress: Double
    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let fraction = min(1, max(0, progress))
            // Only the needle may cross the redline; the filled arc stays on its rail.
            let needleFraction = min(1.12, max(-0.06, progress))
            let edge = min(size.width, size.height)
            let hub = CGPoint(x: size.width / 2, y: size.height / 2 + edge * 0.06)
            let radius = edge * 0.43
            let width = edge * 0.085
            func point(_ fraction: Double, radius: CGFloat) -> CGPoint {
                let angle = (135 + 270 * fraction) * .pi / 180
                return CGPoint(x: hub.x + radius * CGFloat(cos(angle)),
                               y: hub.y + radius * CGFloat(sin(angle)))
            }
            func arc(to fraction: Double) -> Path {
                var path = Path()
                path.addArc(center: hub, radius: radius, startAngle: .degrees(135),
                            endAngle: .degrees(135 + 270 * fraction), clockwise: false)
                return path
            }
            let stroke = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
            context.stroke(arc(to: 1), with: .color(colorScheme == .dark ? Color(white: 0.52) : Color(uiColor: .systemGray3)), style: stroke)
            context.stroke(arc(to: fraction), with: .color(.primary), style: stroke)
            var needle = Path()
            let needleHub = CGPoint(x: hub.x, y: hub.y + edge * 0.035)
            let tip = point(needleFraction, radius: radius * 0.61)
            needle.move(to: needleHub)
            needle.addLine(to: tip)
            context.stroke(needle, with: .color(.primary), style: stroke)
            context.fill(Path(ellipseIn: CGRect(x: needleHub.x - width, y: needleHub.y - width,
                                               width: width * 2, height: width * 2)), with: .color(.primary))
        }
        .accessibilityHidden(true)
    }
}

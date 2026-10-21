import SwiftUI

/// Shared monochrome artwork for the floating menu and input-area sheets.
struct ComposerMenuSymbol: View {
    let level: ComposerActionMenuLevel
    var thinking: ThinkingEffort?
    var supportedLevels: [ThinkingEffort] = ThinkingEffort.allCases

    @ViewBuilder var body: some View {
        switch level {
        case .models:
            // A compact network: layered nodes represent a model rather than a generic sparkle.
            Canvas { context, size in
                let edge = min(size.width, size.height)
                let origin = CGPoint(x: (size.width - edge) / 2, y: (size.height - edge) / 2)
                let columns: [[CGPoint]] = [
                    [CGPoint(x: 0.16, y: 0.30), CGPoint(x: 0.16, y: 0.70)],
                    [CGPoint(x: 0.50, y: 0.14), CGPoint(x: 0.50, y: 0.50), CGPoint(x: 0.50, y: 0.86)],
                    [CGPoint(x: 0.84, y: 0.30), CGPoint(x: 0.84, y: 0.70)]
                ].map { $0.map { CGPoint(x: origin.x + $0.x * edge, y: origin.y + $0.y * edge) } }
                var connections = Path()
                let nodeRadius = edge * 0.075
                for column in 0..<2 {
                    for start in columns[column] {
                        for end in columns[column + 1] {
                            let dx = end.x - start.x, dy = end.y - start.y
                            let length = hypot(dx, dy)
                            connections.move(to: CGPoint(x: start.x + dx / length * nodeRadius,
                                                          y: start.y + dy / length * nodeRadius))
                            connections.addLine(to: CGPoint(x: end.x - dx / length * nodeRadius,
                                                            y: end.y - dy / length * nodeRadius))
                        }
                    }
                }
                context.stroke(connections, with: .color(.primary),
                               style: StrokeStyle(lineWidth: edge * 0.045, lineCap: .round))
                for node in columns.flatMap({ $0 }) {
                    context.fill(Path(ellipseIn: CGRect(x: node.x - nodeRadius, y: node.y - nodeRadius,
                        width: nodeRadius * 2, height: nodeRadius * 2)), with: .color(.primary))
                }
            }
        case .thinking:
            if let thinking { ComposerThinkingIcon(level: thinking, supportedLevels: supportedLevels) }
            else { Image(systemName: "tachometer").resizable().scaledToFit().fontWeight(.medium) }
        case .plugins:
            Canvas { context, size in
                let edge = min(size.width, size.height)
                let transform = CGAffineTransform(scaleX: edge / 28, y: edge / 28)
                    .concatenating(CGAffineTransform(translationX: (size.width - edge) / 2,
                                                    y: (size.height - edge) / 2))
                var cord = Path()
                // Tangent-continuous curves: the tail leaves the plug vertically,
                // then follows one open loop with clearance around the two pins.
                cord.move(to: CGPoint(x: 14, y: 16))
                cord.addCurve(to: CGPoint(x: 24, y: 15), control1: CGPoint(x: 14, y: 23), control2: CGPoint(x: 24, y: 23))
                cord.addCurve(to: CGPoint(x: 14, y: 3), control1: CGPoint(x: 24, y: 8), control2: CGPoint(x: 21, y: 3))
                cord.addCurve(to: CGPoint(x: 3, y: 14), control1: CGPoint(x: 8, y: 3), control2: CGPoint(x: 3, y: 7))
                cord.addCurve(to: CGPoint(x: 15, y: 25), control1: CGPoint(x: 3, y: 21), control2: CGPoint(x: 8, y: 25))
                var plug = Path(roundedRect: CGRect(x: 10, y: 10, width: 8, height: 6), cornerRadius: 2)
                plug.move(to: CGPoint(x: 12, y: 10)); plug.addLine(to: CGPoint(x: 12, y: 7))
                plug.move(to: CGPoint(x: 16, y: 10)); plug.addLine(to: CGPoint(x: 16, y: 7))
                let stroke = StrokeStyle(lineWidth: edge * 0.075, lineCap: .round, lineJoin: .round)
                context.stroke(cord.applying(transform), with: .color(.primary), style: stroke)
                context.stroke(plug.applying(transform), with: .color(.primary), style: stroke)
            }
            .rotationEffect(.degrees(-45))
        case .files:
            Image(systemName: "paperclip").resizable().scaledToFit().fontWeight(.medium)
                // Shorten the tall SF silhouette while retaining its familiar double loop.
                .scaleEffect(x: 1, y: 0.82)
        case .images:
            Image(systemName: "photo.on.rectangle.angled").resizable().scaledToFit().fontWeight(.medium)
        case .actions:
            Image(systemName: "plus").resizable().scaledToFit()
        }
    }
}

import SwiftUI

/// Shared monochrome artwork for the floating menu and input-area sheets.
struct ComposerMenuSymbol: View {
    let level: ComposerActionMenuLevel
    var thinking: ThinkingEffort?
    var supportedLevels: [ThinkingEffort] = ThinkingEffort.allCases

    @ViewBuilder var body: some View {
        switch level {
        case .models:
            // Explicit shading also resolves inside hosted Liquid Glass content.
            Canvas { context, size in
                let edge = min(size.width, size.height)
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                // A softly twisted four-point sparkle, rather than a brand mark.
                var path = Path()
                for step in 0...160 {
                    let angle = Double(step) / 160 * 2 * .pi
                    let radius = edge * CGFloat(0.31 + 0.13 * cos(4 * angle))
                    let twist = angle + 0.18 * sin(4 * angle)
                    let point = CGPoint(x: center.x + radius * CGFloat(cos(twist)),
                                        y: center.y + radius * CGFloat(sin(twist)))
                    if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                path.closeSubpath()
                context.stroke(path, with: .color(.primary),
                               style: StrokeStyle(lineWidth: edge * 0.08, lineCap: .round, lineJoin: .round))
                context.fill(Path(ellipseIn: CGRect(x: center.x - edge * 0.06, y: center.y - edge * 0.06,
                                 width: edge * 0.12, height: edge * 0.12)), with: .color(.primary))
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
                cord.move(to: CGPoint(x: 14, y: 17))
                cord.addCurve(to: CGPoint(x: 23, y: 17), control1: CGPoint(x: 13, y: 24), control2: CGPoint(x: 23, y: 23))
                cord.addCurve(to: CGPoint(x: 14, y: 3), control1: CGPoint(x: 27, y: 10), control2: CGPoint(x: 22, y: 3))
                cord.addCurve(to: CGPoint(x: 3, y: 14), control1: CGPoint(x: 8, y: 3), control2: CGPoint(x: 3, y: 7))
                cord.addCurve(to: CGPoint(x: 18, y: 25), control1: CGPoint(x: 3, y: 22), control2: CGPoint(x: 10, y: 27))
                var plug = Path(roundedRect: CGRect(x: 10, y: 10, width: 8, height: 7), cornerRadius: 2)
                plug.move(to: CGPoint(x: 12, y: 10)); plug.addLine(to: CGPoint(x: 12, y: 6))
                plug.move(to: CGPoint(x: 16, y: 10)); plug.addLine(to: CGPoint(x: 16, y: 6))
                let stroke = StrokeStyle(lineWidth: edge * 0.075, lineCap: .round, lineJoin: .round)
                context.stroke(cord.applying(transform), with: .color(.primary), style: stroke)
                context.stroke(plug.applying(transform), with: .color(.primary), style: stroke)
            }
            .rotationEffect(.degrees(-45))
        case .files:
            Image(systemName: "paperclip").resizable().scaledToFit().fontWeight(.medium)
        case .images:
            Image(systemName: "photo.on.rectangle.angled").resizable().scaledToFit().fontWeight(.medium)
        case .actions:
            Image(systemName: "plus").resizable().scaledToFit()
        }
    }
}

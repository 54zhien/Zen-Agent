import SwiftUI

/// Shared 28-unit optical grid; narrow artwork has a little more height so its
/// perceived size matches the round symbols in both primary and detail menus.
struct ComposerMenuSymbol: View {
    let level: ComposerActionMenuLevel
    var thinking: ThinkingEffort?
    var supportedLevels: [ThinkingEffort] = ThinkingEffort.allCases

    @ViewBuilder var body: some View {
        switch level {
        case .thinking:
            if let thinking { ComposerThinkingIcon(level: thinking, supportedLevels: supportedLevels) }
            else { Image(systemName: "tachometer").resizable().scaledToFit().fontWeight(.medium) }
        case .models, .plugins, .files, .images:
            Canvas { context, size in
                let edge = min(size.width, size.height)
                let transform = CGAffineTransform(scaleX: edge / 28, y: edge / 28)
                    .concatenating(CGAffineTransform(translationX: (size.width - edge) / 2,
                                                    y: (size.height - edge) / 2))
                var path = Path()
                var detail = Path()
                switch level {
                case .models:
                    let orbit = Path(ellipseIn: CGRect(x: 8.25, y: 1.5, width: 11.5, height: 25))
                    for angle in [-Double.pi / 4, Double.pi / 4] {
                        let rotation = CGAffineTransform(translationX: 14, y: 14)
                            .rotated(by: angle).translatedBy(x: -14, y: -14)
                        path.addPath(orbit.applying(rotation))
                    }
                case .plugins:
                    // Trace the reference in its final orientation. Separating
                    // the inner plug avoids an oversized joint in the cord.
                    path.addArc(center: CGPoint(x: 14, y: 14), radius: 10.5,
                                startAngle: .degrees(55), endAngle: .degrees(360), clockwise: false)
                    path.addCurve(to: CGPoint(x: 16.8, y: 17.8),
                                  control1: CGPoint(x: 24.5, y: 18.5), control2: CGPoint(x: 21.5, y: 20))
                    detail.move(to: CGPoint(x: 9.6, y: 15))
                    detail.addLine(to: CGPoint(x: 15, y: 9.6))
                    detail.addLine(to: CGPoint(x: 17.3, y: 11.9))
                    detail.addCurve(to: CGPoint(x: 16.8, y: 17.8),
                                    control1: CGPoint(x: 19.3, y: 13.9), control2: CGPoint(x: 18.5, y: 16.1))
                    detail.addCurve(to: CGPoint(x: 11.2, y: 17.8),
                                    control1: CGPoint(x: 15.1, y: 19.5), control2: CGPoint(x: 13.1, y: 19.7))
                    detail.closeSubpath()
                    detail.move(to: CGPoint(x: 10.9, y: 13.7)); detail.addLine(to: CGPoint(x: 9.3, y: 12.1))
                    detail.move(to: CGPoint(x: 13.7, y: 10.9)); detail.addLine(to: CGPoint(x: 12.1, y: 9.3))
                case .files:
                    path.move(to: CGPoint(x: 7, y: 9)); path.addLine(to: CGPoint(x: 7, y: 18))
                    path.addCurve(to: CGPoint(x: 21, y: 18), control1: CGPoint(x: 7, y: 27), control2: CGPoint(x: 21, y: 27))
                    path.addLine(to: CGPoint(x: 21, y: 8))
                    path.addCurve(to: CGPoint(x: 11.5, y: 8), control1: CGPoint(x: 21, y: 1), control2: CGPoint(x: 11.5, y: 1))
                    path.addLine(to: CGPoint(x: 11.5, y: 18))
                    path.addCurve(to: CGPoint(x: 16.5, y: 18), control1: CGPoint(x: 11.5, y: 22), control2: CGPoint(x: 16.5, y: 22))
                    path.addLine(to: CGPoint(x: 16.5, y: 9))
                case .images:
                    path.addRoundedRect(in: CGRect(x: 3.5, y: 4, width: 21, height: 20), cornerSize: CGSize(width: 4, height: 4))
                    detail.addEllipse(in: CGRect(x: 16, y: 8, width: 4, height: 4))
                    detail.move(to: CGPoint(x: 4, y: 19))
                    detail.addLine(to: CGPoint(x: 9, y: 14))
                    detail.addQuadCurve(to: CGPoint(x: 12, y: 14), control: CGPoint(x: 10.5, y: 12.5))
                    detail.addLine(to: CGPoint(x: 21.5, y: 23.5))
                default: break
                }
                let outline: CGFloat = level == .models ? 2.1 : level == .files ? 2.15 : 2.3
                context.stroke(path.applying(transform), with: .color(.primary),
                               style: StrokeStyle(lineWidth: edge * outline / 28, lineCap: .round, lineJoin: .round))
                context.stroke(detail.applying(transform), with: .color(.primary),
                               style: StrokeStyle(lineWidth: edge * (2.1 / 28), lineCap: .round, lineJoin: .round))
            }
        case .actions:
            Image(systemName: "plus").resizable().scaledToFit()
        }
    }
}

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
            else { Image(systemName: "tachometer").resizable().scaledToFit().fontWeight(.regular) }
        case .models, .plugins, .files, .images:
            Canvas { context, size in
                let edge = min(size.width, size.height)
                let transform = CGAffineTransform(scaleX: edge / 28, y: edge / 28)
                    .concatenating(CGAffineTransform(translationX: (size.width - edge) / 2,
                                                    y: (size.height - edge) / 2))
                var path = Path()
                switch level {
                case .models:
                    let orbit = Path(ellipseIn: CGRect(x: 8.25, y: 1.5, width: 11.5, height: 25))
                    for angle in [-Double.pi / 4, Double.pi / 4] {
                        let rotation = CGAffineTransform(translationX: 14, y: 14)
                            .rotated(by: angle).translatedBy(x: -14, y: -14)
                        path.addPath(orbit.applying(rotation))
                    }
                case .plugins:
                    let rotation = CGAffineTransform(translationX: 14, y: 14)
                        .rotated(by: -.pi / 4).translatedBy(x: -14, y: -14)
                    // Rounded plug shoulders and two distinct prongs. The cord
                    // joins the rounded rear tangentially instead of crossing it.
                    var plug = Path()
                    plug.move(to: CGPoint(x: 10, y: 10))
                    plug.addLine(to: CGPoint(x: 18, y: 10))
                    plug.addLine(to: CGPoint(x: 18, y: 14))
                    plug.addCurve(to: CGPoint(x: 14, y: 18), control1: CGPoint(x: 18, y: 16.21), control2: CGPoint(x: 16.21, y: 18))
                    plug.addCurve(to: CGPoint(x: 10, y: 14), control1: CGPoint(x: 11.79, y: 18), control2: CGPoint(x: 10, y: 16.21))
                    plug.closeSubpath()
                    plug.move(to: CGPoint(x: 12, y: 10)); plug.addLine(to: CGPoint(x: 12, y: 7))
                    plug.move(to: CGPoint(x: 16, y: 10)); plug.addLine(to: CGPoint(x: 16, y: 7))
                    path.addPath(plug.applying(rotation))
                    var cord = Path()
                    cord.addArc(center: CGPoint(x: 14, y: 14), radius: 10.3,
                                startAngle: .degrees(52), endAngle: .degrees(360), clockwise: false)
                    cord.addCurve(to: CGPoint(x: 14, y: 18).applying(rotation),
                                  control1: CGPoint(x: 24.3, y: 21.5), control2: CGPoint(x: 21.5, y: 21.5))
                    path.addPath(cord)
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
                    path.addEllipse(in: CGRect(x: 16, y: 8, width: 4, height: 4))
                    path.move(to: CGPoint(x: 4, y: 19))
                    path.addLine(to: CGPoint(x: 9, y: 14))
                    path.addQuadCurve(to: CGPoint(x: 12, y: 14), control: CGPoint(x: 10.5, y: 12.5))
                    path.addLine(to: CGPoint(x: 21.5, y: 23.5))
                default: break
                }
                context.stroke(path.applying(transform), with: .color(.primary),
                               style: StrokeStyle(lineWidth: edge * (1.8 / 28), lineCap: .round, lineJoin: .round))
            }
        case .actions:
            Image(systemName: "plus").resizable().scaledToFit()
        }
    }
}

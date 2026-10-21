import SwiftUI

/// Shared outline artwork follows the owner's reference proportions.
struct ComposerMenuSymbol: View {
    let level: ComposerActionMenuLevel
    var thinking: ThinkingEffort?
    var supportedLevels: [ThinkingEffort] = ThinkingEffort.allCases

    @ViewBuilder var body: some View {
        switch level {
        case .models:
            ZStack {
                Ellipse().stroke(Color.primary, lineWidth: 2.1)
                    .frame(width: 12, height: 25).rotationEffect(.degrees(45))
                Ellipse().stroke(Color.primary, lineWidth: 2.1)
                    .frame(width: 12, height: 25).rotationEffect(.degrees(-45))
            }
        case .thinking:
            if let thinking { ComposerThinkingIcon(level: thinking, supportedLevels: supportedLevels) }
            else { Image(systemName: "tachometer").resizable().scaledToFit().fontWeight(.medium) }
        case .plugins, .files, .images:
            Canvas { context, size in
                let edge = min(size.width, size.height)
                let transform = CGAffineTransform(scaleX: edge / 28, y: edge / 28)
                    .concatenating(CGAffineTransform(translationX: (size.width - edge) / 2,
                                                    y: (size.height - edge) / 2))
                var path = Path()
                switch level {
                case .plugins:
                    // Apply rotation around the plug's center, keeping the cord circular.
                    let rotation = CGAffineTransform(translationX: 14, y: 14)
                        .rotated(by: -.pi / 4).translatedBy(x: -14, y: -14)
                    var plug = Path(roundedRect: CGRect(x: 10.5, y: 11, width: 7, height: 6), cornerRadius: 1.5)
                    plug.move(to: CGPoint(x: 12, y: 11)); plug.addLine(to: CGPoint(x: 12, y: 7.5))
                    plug.move(to: CGPoint(x: 16, y: 11)); plug.addLine(to: CGPoint(x: 16, y: 7.5))
                    path.addPath(plug.applying(rotation))
                    path.move(to: CGPoint(x: 14, y: 17).applying(rotation))
                    path.addCurve(to: CGPoint(x: 23, y: 14), control1: CGPoint(x: 20.5, y: 21), control2: CGPoint(x: 23, y: 19))
                    path.addArc(center: CGPoint(x: 14, y: 14), radius: 9, startAngle: .degrees(0),
                                endAngle: .degrees(-290), clockwise: true)
                case .files:
                    path.move(to: CGPoint(x: 8, y: 9)); path.addLine(to: CGPoint(x: 8, y: 18))
                    path.addCurve(to: CGPoint(x: 21, y: 18), control1: CGPoint(x: 8, y: 27), control2: CGPoint(x: 21, y: 27))
                    path.addLine(to: CGPoint(x: 21, y: 8))
                    path.addCurve(to: CGPoint(x: 12, y: 8), control1: CGPoint(x: 21, y: 1), control2: CGPoint(x: 12, y: 1))
                    path.addLine(to: CGPoint(x: 12, y: 18))
                    path.addCurve(to: CGPoint(x: 17, y: 18), control1: CGPoint(x: 12, y: 22), control2: CGPoint(x: 17, y: 22))
                    path.addLine(to: CGPoint(x: 17, y: 9))
                case .images:
                    path.addRoundedRect(in: CGRect(x: 3, y: 4, width: 22, height: 20), cornerSize: CGSize(width: 4, height: 4))
                    path.addEllipse(in: CGRect(x: 16.5, y: 8, width: 4, height: 4))
                    path.move(to: CGPoint(x: 4, y: 19))
                    path.addLine(to: CGPoint(x: 9, y: 14))
                    path.addQuadCurve(to: CGPoint(x: 12, y: 14), control: CGPoint(x: 10.5, y: 12.5))
                    path.addLine(to: CGPoint(x: 22, y: 23))
                default: break
                }
                context.stroke(path.applying(transform), with: .color(.primary),
                               style: StrokeStyle(lineWidth: edge * 0.085, lineCap: .round, lineJoin: .round))
            }
        case .actions:
            Image(systemName: "plus").resizable().scaledToFit()
        }
    }
}

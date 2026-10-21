import SwiftUI

/// The rail, fill and thumb use one curve, including every frame of a spring snap.
struct ComposerThinkingTrack: View, Animatable {
    var progress: Double
    let count: Int
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let fraction = min(1, max(0, progress))
            func point(_ t: Double) -> CGPoint {
                CGPoint(x: 30 + (size.width - 60) * CGFloat(t),
                        y: size.height - 30 - 38 * CGFloat(4 * t * (1 - t)))
            }
            func curve(to end: Double) -> Path {
                var path = Path()
                path.move(to: point(0))
                for step in 1...100 { path.addLine(to: point(end * Double(step) / 100)) }
                return path
            }
            let rail = curve(to: 1)
            let outline = StrokeStyle(lineWidth: 56, lineCap: .round, lineJoin: .round)
            let stroke = StrokeStyle(lineWidth: 52, lineCap: .round, lineJoin: .round)
            context.stroke(rail, with: .color(Color.primary.opacity(0.09)), style: outline)
            context.stroke(rail, with: .color(Color(uiColor: .tertiarySystemFill)), style: stroke)
            context.stroke(curve(to: fraction), with: .color(.black), style: stroke)
            // A selected first stop still has a circular black base.
            let start = point(0)
            context.fill(Path(ellipseIn: CGRect(x: start.x - 26, y: start.y - 26, width: 52, height: 52)),
                         with: .color(.black))
            for index in 0..<count {
                let t = Double(index) / Double(max(1, count - 1))
                let dot = point(t)
                context.fill(Path(ellipseIn: CGRect(x: dot.x - 3, y: dot.y - 3, width: 6, height: 6)),
                             with: .color(t <= fraction ? .white.opacity(0.45) : .primary.opacity(0.22)))
            }
            let thumb = point(fraction)
            let circle = Path(ellipseIn: CGRect(x: thumb.x - 21, y: thumb.y - 21, width: 42, height: 42))
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: .black.opacity(0.18), radius: 3, x: 0, y: 1))
                layer.fill(circle, with: .color(.white))
            }
        }
        .accessibilityHidden(true)
    }
}

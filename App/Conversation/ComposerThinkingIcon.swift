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

/// `tachometer` does not vary its needle with SF variableValue. Retain its
/// central SF glyph, rotating around the hub, and draw the requested arc treatment.
struct ComposerThinkingIcon: View {
    let level: ThinkingEffort

    var body: some View {
        GeometryReader { geometry in
            let edge = min(geometry.size.width, geometry.size.height)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    let hub = CGPoint(x: edge / 2, y: edge * 0.58)
                    let radius = edge * 0.45
                    let width = edge * 0.075
                    func point(_ fraction: Double) -> CGPoint {
                        let angle = (135 + 270 * fraction) * .pi / 180
                        return CGPoint(x: hub.x + radius * CGFloat(cos(angle)),
                                       y: hub.y + radius * CGFloat(sin(angle)))
                    }
                    var arc = Path()
                    arc.move(to: point(0))
                    for step in 1...60 { arc.addLine(to: point(level.fraction * Double(step) / 60)) }
                    context.stroke(arc, with: .color(.primary),
                                   style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
                    for step in 0...18 where Double(step) / 18 > level.fraction {
                        let center = point(Double(step) / 18)
                        context.fill(Path(ellipseIn: CGRect(x: center.x - width / 2,
                            y: center.y - width / 2, width: width, height: width)),
                            with: .color(Color(uiColor: .systemGray3)))
                    }
                }
                Image(systemName: "tachometer")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color.primary)
                    .frame(width: edge, height: edge)
                    .mask {
                        Circle().frame(width: edge * 0.72, height: edge * 0.72)
                            .position(x: edge / 2, y: edge * 0.58)
                    }
                    .rotationEffect(.degrees(-90 + 270 * level.fraction),
                                    anchor: UnitPoint(x: 0.5, y: 0.58))
            }
        }
        .accessibilityHidden(true)
    }
}

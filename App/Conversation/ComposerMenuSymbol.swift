import SwiftUI

/// Shared, compact monochrome artwork for both primary menus and detail headers.
struct ComposerMenuSymbol: View {
    let level: ComposerActionMenuLevel
    var thinking: ThinkingEffort?
    var supportedLevels: [ThinkingEffort] = ThinkingEffort.allCases

    @ViewBuilder var body: some View {
        switch level {
        case .models:
            Image(systemName: "cube").resizable().scaledToFit().fontWeight(.medium)
                .scaleEffect(0.92)
        case .thinking:
            if let thinking { ComposerThinkingIcon(level: thinking, supportedLevels: supportedLevels) }
            else { Image(systemName: "tachometer").resizable().scaledToFit().fontWeight(.medium) }
        case .plugins:
            GeometryReader { geometry in
                let edge = min(geometry.size.width, geometry.size.height)
                ZStack {
                    // A circular enclosure, not a stretched cable spline. The
                    // separate plug keeps its original SF proportions and clear pins.
                    Path { path in
                        path.addArc(center: CGPoint(x: edge / 2, y: edge / 2), radius: edge * 0.43,
                                    startAngle: .degrees(65), endAngle: .degrees(355), clockwise: false)
                    }
                    .stroke(Color.primary, style: StrokeStyle(lineWidth: edge * 0.08, lineCap: .round))
                    Image(systemName: "powerplug").resizable().scaledToFit().fontWeight(.medium)
                        .frame(width: edge * 0.52, height: edge * 0.52)
                        .rotationEffect(.degrees(-30))
                }
                .frame(width: edge, height: edge)
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        case .files:
            Image(systemName: "paperclip").resizable().scaledToFit().fontWeight(.medium)
                .rotationEffect(.degrees(-45)).scaleEffect(0.84)
        case .images:
            Image(systemName: "photo").resizable().scaledToFit().fontWeight(.medium)
                .scaleEffect(0.94)
        case .actions:
            Image(systemName: "plus").resizable().scaledToFit()
        }
    }
}

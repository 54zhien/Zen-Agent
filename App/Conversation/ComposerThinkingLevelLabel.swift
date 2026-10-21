import SwiftUI

/// Only committed effort drives the title; drag preview still belongs to the gauge.
struct ComposerThinkingLevelLabel: View {
    let level: ThinkingEffort?
    let font: Font
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayed: ThinkingEffort?
    @State private var direction: CGFloat = 1

    init(level: ThinkingEffort?, font: Font) {
        self.level = level
        self.font = font
        _displayed = State(initialValue: level)
    }

    var body: some View {
        ZStack {
            Text(displayed?.title ?? "模型默认")
                .font(font).lineLimit(1).minimumScaleFactor(0.65)
                .id(displayed)
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .offset(x: direction * 14).combined(with: .opacity),
                    removal: .offset(x: -direction * 14).combined(with: .opacity)))
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
        .onChange(of: level) { oldValue, newValue in
            direction = (newValue?.fraction ?? 0) >= (oldValue?.fraction ?? 0) ? 1 : -1
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.30)) {
                displayed = newValue
            }
        }
    }
}

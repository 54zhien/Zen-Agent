import SwiftUI

/// Feedback follows an accepted selection immediately, including while the rail settles.
struct ComposerThinkingDefaultButton: View {
    let selected: Bool
    let compact: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: selected ? 7 : 0) {
                // Keep one layout identity so both expansion and contraction
                // interpolate instead of inserting/removing a child mid-motion.
                Circle().fill(.white).frame(width: 7, height: 7)
                    .scaleEffect(selected ? 1 : 0.6)
                    .opacity(selected ? 1 : 0)
                    .frame(width: selected ? 7 : 0)
                Text("使用模型默认").font(.system(size: compact ? 17 : 20))
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, compact ? 18 : 22).frame(height: 44)
            .background(selected ? Color.black : Color(uiColor: .tertiarySystemFill), in: Capsule())
            .animation(reduceMotion ? nil : .spring(response: 0.46, dampingFraction: 0.80), value: selected)
        }
        .buttonStyle(DefaultCapsulePressStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("thinking-level-default")
    }
}

private struct DefaultCapsulePressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.30, dampingFraction: 0.80), value: configuration.isPressed)
    }
}

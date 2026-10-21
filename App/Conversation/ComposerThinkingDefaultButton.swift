import SwiftUI

/// Selection follows the committed model-default setting, never the drag preview.
struct ComposerThinkingDefaultButton: View {
    let selected: Bool
    let compact: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if selected {
                    Circle().fill(.white).frame(width: 7, height: 7)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.5).combined(with: .opacity))
                }
                Text("使用模型默认").font(.system(size: compact ? 17 : 20))
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, compact ? 18 : 22).frame(height: 44)
            .background(selected ? Color.black : Color(uiColor: .tertiarySystemFill), in: Capsule())
            .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86), value: selected)
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
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

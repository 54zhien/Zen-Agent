import SwiftUI

/// Feedback follows an accepted selection immediately, including while the rail settles.
struct ComposerThinkingDefaultButton: View {
    let selected: Bool
    let compact: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("使用模型默认").font(.system(size: compact ? 17 : 20))
                .lineLimit(1).minimumScaleFactor(0.75)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, compact ? 18 : 22).frame(height: 44)
                .background(selected ? Color.black : Color(uiColor: .tertiarySystemFill), in: Capsule())
                .animation(nil, value: selected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("thinking-level-default")
    }
}

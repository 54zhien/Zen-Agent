import SwiftUI

/// Preview is continuous; commits use only the model's supported discrete values.
struct ComposerThinkingControl: View {
    let presentation: ComposerActionMenuState
    @State private var dragPosition: Double?
    private let tint = Color(red: 0.69, green: 0.82, blue: 0.05)
    private var efforts: [ThinkingEffort] { presentation.supportedThinkingEfforts }
    private var selectedIndex: Int {
        efforts.firstIndex(where: { $0 == presentation.thinkingLevel }) ?? 0
    }
    private var position: Double { dragPosition ?? Double(selectedIndex) }

    var body: some View {
        GeometryReader { geometry in
            let height = max(120, geometry.size.height - 12)
            ScrollView {
                HStack(spacing: 24) {
                track(height: height)
                VStack(alignment: .leading, spacing: 10) {
                    if let model = presentation.models.first(where: { $0.id == presentation.selectedModelID }) {
                        Text(model.displayName).font(.subheadline).foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    ZStack(alignment: .leading) {
                        ForEach(Array(efforts.enumerated()), id: \.element) { index, effort in
                            Text(effort.title).font(.title.weight(.semibold))
                                .opacity(max(0, 1 - abs(position - Double(index))))
                        }
                    }
                    .accessibilityHidden(true)
                    Text("思考程度").font(.footnote).foregroundStyle(.secondary)
                    Button {
                        dragPosition = nil
                        presentation.onSelectThinking(nil)
                        WorkspaceHaptics.shared.play(.control)
                    } label: {
                        Text(presentation.selectedThinkingEffort == nil ? "模型默认 · 已选" : "使用模型默认")
                            .font(.footnote).padding(.vertical, 12)
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("thinking-level-default")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 28)
                .frame(minHeight: height)
                .padding(.vertical, 6)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .onChange(of: efforts) { _, _ in dragPosition = nil }
    }

    private func track(height: CGFloat) -> some View {
        let width: CGFloat = 64
        let travel = max(1, height - width)
        let count = max(1, efforts.count - 1)
        let fraction = efforts.count == 1 ? 1 : position / Double(count)
        let fillHeight = width - 10 + travel * CGFloat(fraction)
        let thumbY = width / 2 + travel * (1 - CGFloat(fraction))
        return ZStack(alignment: .top) {
            Capsule().fill(.ultraThinMaterial)
            Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            Capsule().fill(tint)
                .frame(width: width - 10, height: fillHeight)
                .position(x: width / 2, y: height - 5 - fillHeight / 2)
            ForEach(Array(efforts.enumerated()), id: \.element) { index, _ in
                Circle().fill(Color.primary.opacity(0.2)).frame(width: 9, height: 9)
                    .position(x: width / 2, y: width / 2 + travel * (1 - (efforts.count == 1 ? 1 : CGFloat(index) / CGFloat(count))))
            }
            Circle().fill(.white).frame(width: 46, height: 46)
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                .position(x: width / 2, y: thumbY)
        }
        .frame(width: width, height: height)
        .contentShape(Capsule())
        .highPriorityGesture(DragGesture(minimumDistance: 0)
            .onChanged { value in
                let next = Double(min(1, max(0, (height - width / 2 - value.location.y) / travel))) * Double(count)
                dragPosition = next
                select(Int(next.rounded()))
            }
            .onEnded { _ in dragPosition = nil })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("思考程度")
        .accessibilityValue(presentation.thinkingLevel?.title ?? "模型默认")
        .accessibilityIdentifier("thinking-vertical-control")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: select(selectedIndex + 1)
            case .decrement: select(selectedIndex - 1)
            @unknown default: break
            }
        }
    }

    private func select(_ index: Int) {
        let index = min(max(0, index), max(0, efforts.count - 1))
        guard efforts.indices.contains(index), presentation.selectedThinkingEffort != efforts[index] else { return }
        presentation.onSelectThinking(efforts[index])
        WorkspaceHaptics.shared.play(.control)
    }
}

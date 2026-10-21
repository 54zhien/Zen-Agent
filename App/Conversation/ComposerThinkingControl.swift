import SwiftUI

/// Dragging previews geometry only. A completed snap commits one supported value.
struct ComposerThinkingControl: View {
    let presentation: ComposerActionMenuState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position = 0.0
    @State private var selectionGeneration = 0
    private var efforts: [ThinkingEffort] { presentation.supportedThinkingEfforts }
    private var selectedIndex: Int {
        efforts.firstIndex(where: { $0 == presentation.thinkingLevel }) ?? 0
    }
    private var modelName: String {
        presentation.models.first(where: { $0.id == presentation.selectedModelID })?.displayName ?? "当前模型"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                track
                    .frame(height: 108)
                Text(presentation.thinkingLevel?.title ?? "模型默认")
                    .font(.title2.weight(.semibold))
                    .accessibilityIdentifier("thinking-committed-level")
                Text(modelName)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Button { settle(on: nil) } label: {
                    HStack(spacing: 7) {
                        if presentation.selectedThinkingEffort == nil {
                            Image(systemName: "checkmark").font(.footnote.weight(.semibold))
                        }
                        Text("使用模型默认").font(.subheadline)
                    }
                    .padding(.horizontal, 18).frame(minHeight: 44)
                    .background(.quaternary, in: Capsule())
                }
                .accessibilityAddTraits(presentation.selectedThinkingEffort == nil ? .isSelected : [])
                .accessibilityIdentifier("thinking-level-default")
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28).padding(.bottom, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onAppear { synchronize() }
        .onDisappear { selectionGeneration += 1 }
        .onChange(of: efforts) { _, _ in synchronize() }
        .onChange(of: presentation.selectedModelID) { _, _ in synchronize() }
        .onChange(of: presentation.thinkingLevel) { _, _ in synchronize() }
        .onChange(of: presentation.activeLevel) { _, level in
            if level != .thinking { selectionGeneration += 1 }
        }
    }

    private var track: some View {
        GeometryReader { geometry in
            ComposerThinkingTrack(progress: position / Double(max(1, efforts.count - 1)), count: efforts.count)
                .contentShape(Rectangle())
                .highPriorityGesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        selectionGeneration += 1
                        let fraction = min(1, max(0, (value.location.x - 30) / max(1, geometry.size.width - 60)))
                        var transaction = Transaction(animation: nil)
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { position = Double(fraction) * Double(max(0, efforts.count - 1)) }
                    }
                    .onEnded { _ in
                        let index = min(max(0, Int(position.rounded())), max(0, efforts.count - 1))
                        if efforts.indices.contains(index) { settle(on: efforts[index]) }
                    })
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("思考程度")
        .accessibilityValue(presentation.thinkingLevel?.title ?? "模型默认")
        .accessibilityIdentifier("thinking-curved-control")
        .accessibilityAdjustableAction { direction in
            let index: Int
            switch direction {
            case .increment: index = min(selectedIndex + 1, efforts.count - 1)
            case .decrement: index = max(selectedIndex - 1, 0)
            @unknown default: return
            }
            if efforts.indices.contains(index) { settle(on: efforts[index]) }
        }
    }

    private func synchronize() {
        selectionGeneration += 1
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { position = Double(selectedIndex) }
    }

    private func settle(on effort: ThinkingEffort?) {
        guard presentation.activeLevel == .thinking else { return }
        let target = effort ?? presentation.defaultLevel
        let index = efforts.firstIndex(where: { $0 == target }) ?? 0
        selectionGeneration += 1
        let generation = selectionGeneration
        let modelID = presentation.selectedModelID
        let supported = efforts
        // Removed waits for the spring's settling tail. A new drag, model or
        // dismissal invalidates the completion instead of committing stale input.
        withAnimation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.76),
                      completionCriteria: .removed) {
            position = Double(index)
        } completion: {
            guard generation == selectionGeneration,
                  presentation.activeLevel == .thinking,
                  presentation.selectedModelID == modelID, efforts == supported else { return }
            guard presentation.selectedThinkingEffort != effort else { return }
            presentation.onSelectThinking(effort)
            WorkspaceHaptics.shared.play(.control)
        }
    }
}

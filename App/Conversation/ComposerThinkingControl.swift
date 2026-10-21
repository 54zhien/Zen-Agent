import SwiftUI

/// Dragging previews geometry only. A completed snap commits one supported value.
struct ComposerThinkingControl: View {
    let presentation: ComposerActionMenuState
    var compactLayout = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position = 0.0
    @State private var selectionGeneration = 0
    @State private var isDragging = false
    @GestureState private var touchActive = false
    @State private var isSettling = false
    @State private var pendingSelection: ThinkingEffort?
    private var efforts: [ThinkingEffort] { presentation.supportedThinkingEfforts }
    private var selectedIndex: Int {
        efforts.firstIndex(where: { $0 == presentation.thinkingLevel }) ?? 0
    }
    private var modelName: String {
        presentation.models.first(where: { $0.id == presentation.selectedModelID })?.displayName ?? "当前模型"
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = compactLayout || geometry.size.height < 230
            let height = min(142, max(82, geometry.size.height - 100))
            let curve = ComposerThinkingArcGeometry(size: CGSize(width: geometry.size.width - 48, height: height))
            let labelTop = max(0, curve.point(at: 0.5).y + 29)
            if geometry.size.height < 170 {
                HStack(spacing: 12) {
                    track.frame(maxWidth: .infinity)
                    labels(compact: true).frame(maxWidth: .infinity)
                }.padding(.horizontal, 20)
            } else {
                ZStack(alignment: .top) {
                    track.frame(height: height)
                    labels(compact: compact)
                        .padding(.top, labelTop)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .onAppear { synchronize() }
        .onChange(of: presentation.suspensionRevision) { _, _ in synchronize() }
        .onDisappear { cancelPreview() }
        .onChange(of: touchActive) { _, active in
            // GestureState also resets when UIKit cancels without onEnded.
            if !active, isDragging { synchronize() }
        }
        .onChange(of: efforts) { _, _ in synchronize() }
        .onChange(of: presentation.selectedModelID) { _, _ in synchronize() }
        .onChange(of: presentation.thinkingLevel) { _, _ in synchronize() }
        .onChange(of: presentation.activeLevel) { _, level in
            if level != .thinking { cancelPreview() }
        }
    }

    private func labels(compact: Bool) -> some View {
        VStack(spacing: 3) {
            Text(presentation.thinkingLevel?.title ?? "模型默认")
                .font(.system(size: compact ? 28 : 34, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.75)
                .accessibilityIdentifier("thinking-committed-level")
                .allowsHitTesting(false)
            Text(modelName)
                .font(.system(size: compact ? 18 : 22)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.65)
                .padding(.horizontal, 34).allowsHitTesting(false)
            Button { settle(on: nil) } label: {
                HStack(spacing: 7) {
                    if presentation.selectedThinkingEffort == nil {
                        Image(systemName: "checkmark").font(.footnote.weight(.semibold))
                    }
                    Text("使用模型默认").font(.system(size: compact ? 17 : 20))
                        .lineLimit(1).minimumScaleFactor(0.75)
                }
                .padding(.horizontal, compact ? 18 : 22).frame(minHeight: 44)
                .background(.quaternary, in: Capsule())
            }
            .accessibilityAddTraits(presentation.selectedThinkingEffort == nil ? .isSelected : [])
            .accessibilityIdentifier("thinking-level-default")
            .padding(.top, 4)
        }
    }

    private var track: some View {
        GeometryReader { geometry in
            ComposerThinkingTrack(progress: position / Double(max(1, efforts.count - 1)), count: efforts.count)
                .contentShape(Rectangle())
                .highPriorityGesture(DragGesture(minimumDistance: 0)
                    .updating($touchActive) { _, active, _ in active = true }
                    .onChanged { value in
                        guard !presentation.isSuspended, presentation.activeLevel == .thinking else { return }
                        // A touch-down is not a drag: leave the visible position
                        // intact so tapping a detent animates from the old value.
                        let distance = hypot(value.translation.width, value.translation.height)
                        guard isDragging || distance >= 5 else { return }
                        if !isDragging {
                            selectionGeneration += 1
                            isSettling = false
                            isDragging = true
                        }
                        let fraction = ComposerThinkingArcGeometry(size: geometry.size).fraction(at: value.location)
                        var transaction = Transaction(animation: nil)
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { position = fraction * Double(max(0, efforts.count - 1)) }
                        let index = min(max(0, Int(position.rounded())), max(0, efforts.count - 1))
                        if efforts.indices.contains(index) { presentation.previewThinkingEffort = efforts[index] }
                    }
                    .onEnded { value in
                        guard !presentation.isSuspended, presentation.activeLevel == .thinking else { cancelPreview(); return }
                        let fraction = ComposerThinkingArcGeometry(size: geometry.size).fraction(at: value.location)
                        let end = isDragging ? position : fraction * Double(max(0, efforts.count - 1))
                        isDragging = false
                        let index = min(max(0, Int(end.rounded())), max(0, efforts.count - 1))
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

    private func cancelPreview() {
        selectionGeneration += 1
        isDragging = false
        isSettling = false
        presentation.previewThinkingEffort = nil
    }

    private func synchronize() {
        cancelPreview()
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { position = Double(selectedIndex) }
    }

    private func settle(on effort: ThinkingEffort?) {
        guard !presentation.isSuspended, presentation.activeLevel == .thinking else { return }
        let target = effort ?? presentation.defaultLevel
        let index = efforts.firstIndex(where: { $0 == target }) ?? 0
        // Retapping a destination already in flight retains its real completion.
        // Changing default/explicit semantics at that same stop needs no new travel.
        pendingSelection = effort
        if isSettling, position == Double(index) { return }
        selectionGeneration += 1
        isSettling = true
        presentation.previewThinkingEffort = target
        let generation = selectionGeneration
        let suspensionRevision = presentation.suspensionRevision
        let modelID = presentation.selectedModelID
        let supported = efforts
        // Removed waits for the spring's settling tail. A new drag, model or
        // dismissal invalidates the completion instead of committing stale input.
        withAnimation(reduceMotion ? nil : .spring(response: 0.56, dampingFraction: 0.66),
                      completionCriteria: .removed) {
            position = Double(index)
        } completion: {
            guard generation == selectionGeneration,
                  suspensionRevision == presentation.suspensionRevision,
                  !presentation.isSuspended, presentation.activeLevel == .thinking,
                  presentation.selectedModelID == modelID, efforts == supported else { return }
            isSettling = false
            if presentation.selectedThinkingEffort != pendingSelection {
                presentation.onSelectThinking(pendingSelection)
                WorkspaceHaptics.shared.play(.control)
            }
            presentation.previewThinkingEffort = nil
        }
    }
}

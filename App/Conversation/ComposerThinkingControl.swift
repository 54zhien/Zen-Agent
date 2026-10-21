import SwiftUI

/// Only the thumb can start a drag. Detents use the same committed-selection
/// path as accessibility and the default button; blank rail space is inert.
struct ComposerThinkingControl: View {
    let presentation: ComposerActionMenuState
    var compactLayout = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position = 0.0
    @State private var selectionGeneration = 0
    @State private var isDragging = false
    @State private var isSettling = false
    @State private var pendingSelection: ThinkingEffort?
    @State private var endpointPulse = 0
    @State private var dragBoundary: Int?
    private var efforts: [ThinkingEffort] { presentation.supportedThinkingEfforts }
    private var selectedIndex: Int {
        efforts.firstIndex(where: { $0 == presentation.thinkingLevel }) ?? 0
    }
    private var modelName: String {
        presentation.models.first(where: { $0.id == presentation.selectedModelID })?.displayName ?? "当前模型"
    }
    private var enabled: Bool { !presentation.isSuspended && presentation.activeLevel == .thinking }

    var body: some View {
        GeometryReader { geometry in
            let minimal = geometry.size.height < 132
            let tiny = geometry.size.height < 160
            let short = geometry.size.height < 210
            let compact = compactLayout || geometry.size.height < 250
            let titleHeight: CGFloat = minimal ? 20 : tiny ? 24 : short ? 26 : compact ? 34 : 42
            let modelHeight: CGFloat = minimal ? 16 : tiny ? 18 : short ? 20 : compact ? 24 : 28
            let railGap: CGFloat = minimal ? 4 : tiny ? 8 : short ? 10 : 18
            let modelGap: CGFloat = tiny ? 2 : short ? 4 : 8
            let buttonGap: CGFloat = tiny ? 4 : short ? 6 : 12
            let bottom: CGFloat = short ? 0 : 4
            let reserved = titleHeight + modelHeight + 44 + railGap + modelGap + buttonGap + bottom
            let railHeight = max(0, min(132, geometry.size.height - reserved))
            let thickness = min(tiny ? 24.0 : short ? 32 : 52, max(4, railHeight - 8))
            VStack(spacing: 0) {
                track(thickness: thickness)
                    .frame(height: railHeight)
                Spacer(minLength: railGap)
                crossfade(presentation.thinkingLevel?.title ?? "模型默认",
                          font: .system(size: minimal ? 18 : tiny ? 20 : short ? 22 : compact ? 28 : 34, weight: .semibold))
                    .frame(height: titleHeight)
                    .accessibilityIdentifier("thinking-committed-level")
                Spacer(minLength: modelGap)
                crossfade(modelName, font: .system(size: tiny ? 14 : short ? 16 : compact ? 18 : 22))
                    .foregroundStyle(.secondary)
                    .frame(height: modelHeight)
                defaultButton(compact: compact)
                    .padding(.top, buttonGap)
            }
            .padding(.horizontal, 24).padding(.bottom, bottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { synchronize() }
        .onChange(of: presentation.suspensionRevision) { _, _ in synchronize() }
        .onDisappear { cancelPreview() }
        .onChange(of: efforts) { _, _ in synchronize() }
        .onChange(of: presentation.selectedModelID) { _, _ in synchronize() }
        .onChange(of: presentation.thinkingLevel) { _, _ in synchronize() }
        .onChange(of: presentation.activeLevel) { _, level in
            if level != .thinking { cancelPreview() }
        }
    }

    private func crossfade(_ value: String, font: Font) -> some View {
        ZStack {
            Text(value).id(value).transition(.opacity)
                .font(font).lineLimit(1).minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.20), value: value)
        .allowsHitTesting(false)
    }

    private func defaultButton(compact: Bool) -> some View {
        Button { settle(on: nil) } label: {
            HStack(spacing: 7) {
                if presentation.selectedThinkingEffort == nil {
                    Image(systemName: "checkmark").font(.footnote.weight(.semibold))
                }
                Text("使用模型默认").font(.system(size: compact ? 17 : 20))
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            .padding(.horizontal, compact ? 18 : 22).frame(height: 44)
            .background(.quaternary, in: Capsule())
        }
        .accessibilityAddTraits(presentation.selectedThinkingEffort == nil ? .isSelected : [])
        .accessibilityIdentifier("thinking-level-default")
    }

    private func track(thickness: CGFloat) -> some View {
        ComposerThinkingTrack(progress: position / Double(max(1, efforts.count - 1)),
            count: efforts.count, thickness: thickness, isDragging: isDragging,
            endpointPulse: endpointPulse, enabled: enabled,
            interactionRevision: presentation.suspensionRevision,
            onDragStarted: { fraction in
                guard enabled else { return }
                selectionGeneration += 1
                isSettling = false
                isDragging = true
                dragBoundary = fraction <= 0 ? 0 : fraction >= 1 ? efforts.count - 1 : nil
                move(to: fraction)
            }, onDrag: { fraction in
                guard enabled, isDragging else { return }
                move(to: fraction)
            }, onDragEnded: { fraction in
                guard enabled, isDragging else { synchronize(); return }
                move(to: fraction)
                isDragging = false
                let index = min(max(0, Int(position.rounded())), max(0, efforts.count - 1))
                if efforts.indices.contains(index) { settle(on: efforts[index], fromDrag: true) }
            }, onDragCancelled: { synchronize() }, onSelect: { index in
                if efforts.indices.contains(index) { settle(on: efforts[index]) }
            })
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

    private func move(to fraction: Double) {
        let bounded = min(1, max(0, fraction))
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { position = bounded * Double(max(0, efforts.count - 1)) }
        let index = min(max(0, Int(position.rounded())), max(0, efforts.count - 1))
        if efforts.indices.contains(index) { presentation.previewThinkingEffort = efforts[index] }
        let boundary: Int? = bounded <= 0 ? 0 : bounded >= 1 ? efforts.count - 1 : nil
        if let boundary, dragBoundary != boundary { WorkspaceHaptics.shared.play(.control) }
        dragBoundary = boundary
    }

    private func cancelPreview() {
        selectionGeneration += 1
        isDragging = false
        isSettling = false
        dragBoundary = nil
        presentation.previewThinkingEffort = nil
    }

    private func synchronize() {
        cancelPreview()
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { position = Double(selectedIndex) }
    }

    private func settle(on effort: ThinkingEffort?, fromDrag: Bool = false) {
        guard enabled, !isDragging else { return }
        let target = effort ?? presentation.defaultLevel
        let index = efforts.firstIndex(where: { $0 == target }) ?? 0
        pendingSelection = effort
        if isSettling, position == Double(index) { return }
        selectionGeneration += 1
        isSettling = true
        presentation.previewThinkingEffort = target
        let generation = selectionGeneration
        let suspensionRevision = presentation.suspensionRevision
        let modelID = presentation.selectedModelID
        let supported = efforts
        let endpoint = index == 0 || index == efforts.count - 1
        let alreadyArrived = abs(position - Double(index)) < 0.001
        let finish = {
            guard generation == selectionGeneration,
                  suspensionRevision == presentation.suspensionRevision,
                  enabled, presentation.selectedModelID == modelID, efforts == supported else { return }
            isSettling = false
            if presentation.selectedThinkingEffort != pendingSelection {
                presentation.onSelectThinking(pendingSelection)
                if !fromDrag || !endpoint || !alreadyArrived { WorkspaceHaptics.shared.play(.control) }
            }
            presentation.previewThinkingEffort = nil
            if endpoint, !fromDrag || !alreadyArrived { endpointPulse &+= 1 }
        }
        // The rail never overshoots its endpoints. Already-arrived drags commit
        // immediately instead of waiting out an invisible clamped spring tail.
        if alreadyArrived {
            position = Double(index)
            finish()
        } else {
            let animation: Animation? = reduceMotion ? nil : endpoint
                ? .easeOut(duration: 0.22) : .spring(response: 0.40, dampingFraction: 0.82)
            withAnimation(animation, completionCriteria: .removed) {
                position = Double(index)
            } completion: { finish() }
        }
    }
}

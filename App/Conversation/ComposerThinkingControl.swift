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
    @State private var dragSelectionIndex: Int?
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
                    .anchorPreference(key: ComposerThinkingLabelAnchors.self, value: .bounds) { [.rail: $0] }
                Spacer(minLength: railGap)
                // Reserve the original title budget so only the visible label
                // moves; rail, model name and default capsule keep their layout.
                Color.clear.frame(height: titleHeight)
                    .allowsHitTesting(false).accessibilityHidden(true)
                Spacer(minLength: modelGap)
                crossfade(modelName, font: .system(size: tiny ? 14 : short ? 16 : compact ? 18 : 22))
                    .foregroundStyle(.secondary)
                    .frame(height: modelHeight)
                    .anchorPreference(key: ComposerThinkingLabelAnchors.self, value: .bounds) { [.model: $0] }
                defaultButton(compact: compact)
                    .padding(.top, buttonGap)
            }
            .padding(.horizontal, 24).padding(.bottom, bottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlayPreferenceValue(ComposerThinkingLabelAnchors.self) { anchors in
                GeometryReader { layout in
                    if let railAnchor = anchors[.rail], let modelAnchor = anchors[.model] {
                        let rail = layout[railAnchor]
                        let model = layout[modelAnchor]
                        let curve = ComposerThinkingArcGeometry(size: rail.size, inset: thickness / 2 + 4)
                        let lowerArcY = rail.minY + curve.point(at: 0.5).y + thickness / 2
                        ComposerThinkingLevelLabel(level: presentation.thinkingLevel,
                            font: .system(size: minimal ? 18 : tiny ? 20 : short ? 22 : compact ? 28 : 34,
                                          weight: .semibold))
                            .frame(width: rail.width, height: titleHeight)
                            .position(x: rail.midX, y: (lowerArcY + model.minY) / 2)
                            .accessibilityIdentifier("thinking-committed-level")
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .onAppear {
            synchronize()
            WorkspaceHaptics.shared.prepareThinking()
        }
        .onChange(of: presentation.suspensionRevision) { _, _ in synchronize() }
        .onChange(of: presentation.isSuspended) { _, suspended in
            if suspended {
                WorkspaceHaptics.shared.stopThinking()
            } else if enabled {
                WorkspaceHaptics.shared.prepareThinking()
            }
        }
        .onDisappear {
            cancelPreview()
            WorkspaceHaptics.shared.stopThinking()
        }
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
        // A tap acknowledges the pending choice immediately. Cancellation falls
        // back to the committed setting; drag previews never select this pill.
        ComposerThinkingDefaultButton(
            selected: isSettling ? pendingSelection == nil : presentation.selectedThinkingEffort == nil,
            compact: compact
        ) { settle(on: nil) }
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
                dragSelectionIndex = nil
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
        if efforts.indices.contains(index) {
            presentation.previewThinkingEffort = efforts[index]
            if isDragging {
                // Track the finger's detent independently of committed model
                // settings. Seed quietly on pickup, then tick on each change.
                let changed = dragSelectionIndex.map { $0 != index } ?? false
                dragSelectionIndex = index
                if changed { WorkspaceHaptics.shared.play(.thinkingDetent) }
            }
        }
    }

    private func cancelPreview() {
        selectionGeneration += 1
        isDragging = false
        isSettling = false
        dragSelectionIndex = nil
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
                if !fromDrag { WorkspaceHaptics.shared.play(.thinkingDetent) }
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

/// Bounds are resolved in one layout pass; no state-driven geometry feedback.
private struct ComposerThinkingLabelAnchors: PreferenceKey {
    enum Element: Hashable { case rail, model }
    static var defaultValue: [Element: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [Element: Anchor<CGRect>],
                       nextValue: () -> [Element: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

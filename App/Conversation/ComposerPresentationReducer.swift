import Foundation

struct ComposerCollapseProgress: Equatable, Sendable {
    let value: Double

    init?(value: Double) {
        guard value.isFinite, (0.0...1.0).contains(value) else { return nil }
        self.value = value
    }

    private init(uncheckedValue: Double) {
        value = uncheckedValue
    }

    static let expanded = Self(uncheckedValue: 0.0)
    static let fullyCollapsed = Self(uncheckedValue: 1.0)
}

enum ComposerPresentationEvent: Equatable, Sendable {
    case textAreaTapped
    case conversationBackgroundTapped
    case keyboardDismissed
    case timelineCollapseProgressChanged
    case compactTapped
    case compositionEnded
    case quoteDragPhaseChanged(ComposerQuoteDragPhase)
    case selectionHandleDragChanged(Bool)
    case quoteDropCommitted
}

enum ComposerQuoteDragPhase: Equatable, Sendable {
    case idle
    case active
    case overDropZone
}

enum ComposerPendingExitIntent: Equatable, Sendable {
    case conversationBackgroundTap
    case keyboardDismissed
}

enum ComposerFocusCommand: Equatable, Sendable {
    case none
    case requestFocus
    case requestResign
}

struct ComposerTransition: Equatable, Sendable {
    let targetState: ComposerPresentationState
    let pendingExit: ComposerPendingExitIntent?
    let focusCommand: ComposerFocusCommand
}

enum ComposerPresentationReducer {
    static let compactEnterThreshold = 0.72
    static let compactExitThreshold = 0.58

    static func reduce(
        current: ComposerPresentationState,
        event: ComposerPresentationEvent,
        isComposing: Bool,
        collapseProgress: ComposerCollapseProgress,
        pendingExit: ComposerPendingExitIntent?
    ) -> ComposerTransition {
        if isComposing, current != .editing {
            return transition(.editing, pendingExit, .none)
        }

        switch event {
        case .textAreaTapped:
            guard current == .resting else { return transition(current, pendingExit, .none) }
            return transition(.editing, nil, .requestFocus)

        case .compactTapped:
            guard current == .compact else { return transition(current, pendingExit, .none) }
            return transition(.editing, nil, .requestFocus)

        case .conversationBackgroundTapped:
            guard current == .editing else { return transition(current, pendingExit, .none) }
            if isComposing {
                return transition(.editing, .conversationBackgroundTap, .none)
            }
            return transition(.resting, nil, .requestResign)

        case .keyboardDismissed:
            guard current == .editing else { return transition(current, pendingExit, .none) }
            if isComposing {
                return transition(.editing, .keyboardDismissed, .none)
            }
            return transition(.resting, nil, .none)

        case .timelineCollapseProgressChanged:
            guard !isComposing else { return transition(.editing, pendingExit, .none) }
            switch current {
            case .resting:
                let target: ComposerPresentationState = collapseProgress.value >= compactEnterThreshold
                    ? .compact
                    : .resting
                return transition(target, pendingExit, .none)
            case .compact:
                let target: ComposerPresentationState = collapseProgress.value <= compactExitThreshold
                    ? .resting
                    : .compact
                return transition(target, pendingExit, .none)
            case .editing:
                return transition(.editing, pendingExit, .none)
            }

        case .compositionEnded:
            guard current == .editing, !isComposing else {
                return transition(current, pendingExit, .none)
            }
            guard let pendingExit else { return transition(.editing, nil, .none) }
            let focus: ComposerFocusCommand = pendingExit == .conversationBackgroundTap
                ? .requestResign
                : .none
            return transition(.resting, nil, focus)

        case .quoteDragPhaseChanged(let phase):
            if phase == .overDropZone, current == .compact {
                return transition(.resting, pendingExit, .none)
            }
            return transition(current, pendingExit, .none)

        case .selectionHandleDragChanged:
            return transition(current, pendingExit, .none)

        case .quoteDropCommitted:
            return transition(.resting, nil, .none)
        }
    }

    private static func transition(
        _ state: ComposerPresentationState,
        _ pendingExit: ComposerPendingExitIntent?,
        _ focusCommand: ComposerFocusCommand
    ) -> ComposerTransition {
        ComposerTransition(
            targetState: state,
            pendingExit: pendingExit,
            focusCommand: focusCommand
        )
    }
}

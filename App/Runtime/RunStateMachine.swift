import Foundation

enum RunStateMachineError: Error, Equatable, Sendable {
    case invalidTransition(from: RunState, to: RunState)
}

/// The only state edges available to Stage 2. Terminal states deliberately have no
/// outgoing edges, so a stale writer cannot revive a completed, failed or cancelled
/// run through an in-memory transition helper.
struct RunStateMachine: Sendable {
    static func allowedTransitions(from state: RunState) -> [RunState] {
        switch state {
        case .preparing:
            return [.requestingModel, .stopping, .suspended, .failed]
        case .requestingModel:
            return [.streaming, .toolRequested, .stopping, .suspended, .failed]
        case .streaming:
            return [.toolRequested, .completed, .stopping, .suspended, .failed]
        case .toolRequested:
            return [.waitingForApproval, .executingTools, .stopping, .failed]
        case .waitingForApproval:
            return [.executingTools, .continuing, .stopping, .suspended, .failed]
        case .executingTools:
            return [.waitingForApproval, .continuing, .stopping, .suspended, .failed]
        case .continuing:
            return [.requestingModel, .stopping, .suspended, .failed]
        case .stopping:
            return [.cancelled, .failed]
        case .suspended:
            return [.recovering, .stopping, .failed]
        case .recovering:
            return [
                .preparing,
                .requestingModel,
                .waitingForApproval,
                .executingTools,
                .continuing,
                .stopping,
                .failed,
            ]
        case .completed, .failed, .cancelled:
            return []
        }
    }

    static func canTransition(from: RunState, to: RunState) -> Bool {
        allowedTransitions(from: from).contains(to)
    }

    static func validate(from: RunState, to: RunState) throws {
        guard canTransition(from: from, to: to) else {
            throw RunStateMachineError.invalidTransition(from: from, to: to)
        }
    }

    @discardableResult
    static func transition(from: RunState, to: RunState) throws -> RunState {
        try validate(from: from, to: to)
        return to
    }
}

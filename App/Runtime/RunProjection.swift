import Foundation

struct RunProjection: Sendable, Equatable {
    var runID: String
    var state: RunState
    var isActive: Bool
    var canStop: Bool
    var isWaitingForApproval: Bool
    var isSuspended: Bool
}

extension RunProjection {
    init(runID: String, state: RunState) {
        self.runID = runID
        self.state = state
        self.isActive = state.isActive
        self.canStop = state.isActive && state != .stopping
        self.isWaitingForApproval = state == .waitingForApproval
        self.isSuspended = state == .suspended
    }

    /// Builds a projection when an event contains enough state to establish one.
    /// Content events are intentionally not accepted as an alternate source of run
    /// state; they can only be applied after a run projection already exists.
    init?(event: AgentEvent) {
        switch event {
        case .runAccepted(let runID, _):
            self.init(runID: runID, state: .preparing)
        case .runStateChanged(let runID, let state):
            self.init(runID: runID, state: state)
        case .approvalRequired:
            return nil
        case .runEnded(let runID, let state, _):
            self.init(runID: runID, state: state)
        case .messagePartStarted,
             .messagePartDelta,
             .messagePartCompleted,
             .toolCallChanged:
            return nil
        }
    }

    /// Applies business events only. Provider DTOs never enter this type.
    mutating func apply(_ event: AgentEvent) {
        let eventRunID: String
        let nextState: RunState?

        switch event {
        case .runAccepted(let runID, _):
            eventRunID = runID
            nextState = .preparing
        case .runStateChanged(let runID, let state):
            eventRunID = runID
            nextState = state
        case .approvalRequired(let runID, _):
            eventRunID = runID
            nextState = nil
        case .runEnded(let runID, let state, _):
            eventRunID = runID
            nextState = state
        case .messagePartStarted(let runID, _, _, _):
            eventRunID = runID
            nextState = nil
        case .messagePartDelta(let runID, _, _):
            eventRunID = runID
            nextState = nil
        case .messagePartCompleted(let runID, _, _):
            eventRunID = runID
            nextState = nil
        case .toolCallChanged(let runID, _, _):
            eventRunID = runID
            nextState = nil
        }

        guard eventRunID == runID, let nextState else { return }
        state = nextState
        isActive = nextState.isActive
        canStop = nextState.isActive && nextState != .stopping
        isWaitingForApproval = nextState == .waitingForApproval
        isSuspended = nextState == .suspended
    }

    static func from(_ events: [AgentEvent]) -> RunProjection? {
        var projection: RunProjection?

        for event in events {
            if var current = projection {
                current.apply(event)
                projection = current
            } else if let initial = RunProjection(event: event) {
                projection = initial
            }
        }

        return projection
    }
}

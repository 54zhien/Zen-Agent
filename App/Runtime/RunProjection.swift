import Foundation

struct RunProjection: Sendable, Equatable {
    var runID: String
    var state: RunState
    var endReason: EndReason?
    var isActive: Bool
    var canStop: Bool
    var isWaitingForApproval: Bool
    var isSuspended: Bool
}

extension RunProjection {
    init(runID: String, state: RunState, endReason: EndReason? = nil) {
        self.runID = runID
        self.state = state
        self.endReason = endReason
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
        case .runEnded(let runID, let state, let endReason):
            self.init(runID: runID, state: state, endReason: endReason)
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
        let eventEndReason: EndReason?

        switch event {
        case .runAccepted(let runID, _):
            eventRunID = runID
            nextState = .preparing
            eventEndReason = nil
        case .runStateChanged(let runID, let state):
            eventRunID = runID
            nextState = state
            eventEndReason = nil
        case .approvalRequired(let runID, _):
            eventRunID = runID
            nextState = nil
            eventEndReason = nil
        case .runEnded(let runID, let state, let endReason):
            eventRunID = runID
            nextState = state
            eventEndReason = endReason
        case .messagePartStarted(let runID, _, _, _):
            eventRunID = runID
            nextState = nil
            eventEndReason = nil
        case .messagePartDelta(let runID, _, _, _):
            eventRunID = runID
            nextState = nil
            eventEndReason = nil
        case .messagePartCompleted(let runID, _, _):
            eventRunID = runID
            nextState = nil
            eventEndReason = nil
        case .toolCallChanged(let runID, _, _):
            eventRunID = runID
            nextState = nil
            eventEndReason = nil
        }

        guard eventRunID == runID, let nextState else { return }
        state = nextState
        if let eventEndReason { endReason = eventEndReason }
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

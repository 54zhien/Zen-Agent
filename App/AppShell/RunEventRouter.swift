import Foundation
import Observation

@MainActor
@Observable
final class RunEventRouter {
    private enum PaneLoadState: Equatable {
        case ready
        case waitingForRecovery
    }

    private struct PaneRegistration {
        let pane: ConversationPaneController
        var state: PaneLoadState
    }

    @ObservationIgnored private var conversationByRunID: [String: String] = [:]
    @ObservationIgnored private var acceptedRunOrder: [String] = []
    @ObservationIgnored private var activeRunIDsByConversationID: [String: Set<String>] = [:]
    @ObservationIgnored private var panesByConversationID: [String: PaneRegistration] = [:]
    @ObservationIgnored private var detachedPanesByConversationID: [String: PaneRegistration] = [:]
    @ObservationIgnored private var bufferedEvents: [String: [AgentEvent]] = [:]
    private(set) var diagnostics: [String] = []
    private(set) var recoveryMessages: [String: String] = [:]

    func handle(_ event: AgentEvent) async {
        if case .runAccepted(let runID, let conversationID) = event {
            if let existingConversationID = conversationByRunID[runID] {
                guard existingConversationID == conversationID else {
                    record("Run ownership conflict for \(runID)")
                    return
                }
                return
            }
            conversationByRunID[runID] = conversationID
            acceptedRunOrder.append(runID)
            activeRunIDsByConversationID[conversationID, default: []].insert(runID)
            route(event, runID: runID, to: conversationID)
            return
        }

        let runID = Self.runID(for: event)
        guard let conversationID = conversationByRunID[runID] else {
            record("Dropped unregistered Run event for \(runID)")
            return
        }
        route(event, runID: runID, to: conversationID)
        if case .runEnded = event {
            finishActiveRun(runID, in: conversationID)
        }
    }

    @discardableResult
    func registerPane(_ pane: ConversationPaneController) -> Bool {
        let conversationID = pane.conversationID
        guard panesByConversationID[conversationID] == nil else {
            record("Rejected duplicate Pane registration for \(conversationID)")
            return false
        }

        if let detachedRegistration = detachedPanesByConversationID.removeValue(forKey: conversationID) {
            do {
                try pane.adoptLiveStore(detachedRegistration.pane.liveStore)
            } catch {
                detachedPanesByConversationID[conversationID] = detachedRegistration
                record("Rejected detached LiveStore for mismatched Pane in \(conversationID)")
                return false
            }

            panesByConversationID[conversationID] = PaneRegistration(
                pane: pane,
                state: detachedRegistration.state
            )
            if detachedRegistration.state == .ready {
                recoveryMessages.removeValue(forKey: conversationID)
                replayBufferedEvents(for: conversationID)
            }
            return true
        }

        var registration = PaneRegistration(pane: pane, state: .ready)
        panesByConversationID[conversationID] = registration
        if bufferedEvents[conversationID] != nil {
            do {
                try pane.reloadTimeline()
            } catch {
                registration.state = .waitingForRecovery
                panesByConversationID[conversationID] = registration
                recoveryMessages[conversationID] = "无法加载会话内容，请重试。"
                record("Timeline load failed while registering Pane for \(conversationID)")
                return true
            }
        }
        replayBufferedEvents(for: conversationID)
        if panesByConversationID[conversationID]?.state == .ready {
            recoveryMessages.removeValue(forKey: conversationID)
        }
        return true
    }

    func unregisterPane(for conversationID: String) {
        let registration = panesByConversationID.removeValue(forKey: conversationID)
        if let registration,
           activeRunIDsByConversationID[conversationID]?.isEmpty == false {
            detachedPanesByConversationID[conversationID] = registration
            return
        }

        recoveryMessages.removeValue(forKey: conversationID)
        let pending = bufferedEvents[conversationID] ?? []
        var acceptedEvents: [AgentEvent] = []
        for runID in acceptedRunOrder where conversationByRunID[runID] == conversationID {
            acceptedEvents.append(.runAccepted(runID: runID, conversationID: conversationID))
        }
        let laterEvents = pending.filter { event -> Bool in
            if case .runAccepted = event { return false }
            return true
        }
        let retainedEvents = acceptedEvents + laterEvents
        if retainedEvents.isEmpty {
            bufferedEvents.removeValue(forKey: conversationID)
        } else {
            bufferedEvents[conversationID] = retainedEvents
        }
    }

    func recoveryMessage(for conversationID: String) -> String? {
        recoveryMessages[conversationID]
    }

    @discardableResult
    func retryTimelineLoad(for conversationID: String) -> Bool {
        guard var registration = panesByConversationID[conversationID],
              registration.state == .waitingForRecovery else { return false }

        do {
            try registration.pane.reloadTimeline()
            registration.state = .ready
            panesByConversationID[conversationID] = registration
            recoveryMessages.removeValue(forKey: conversationID)
            replayBufferedEvents(for: conversationID)
            guard let recovered = panesByConversationID[conversationID] else { return false }
            return recovered.state == .ready
        } catch {
            recoveryMessages[conversationID] = "无法加载会话内容，请重试。"
            return false
        }
    }

    private func route(_ event: AgentEvent, runID: String, to conversationID: String) {
        let isDetached = panesByConversationID[conversationID] == nil
        guard var registration = panesByConversationID[conversationID]
                ?? detachedPanesByConversationID[conversationID] else {
            bufferedEvents[conversationID, default: []].append(event)
            return
        }
        guard registration.state == .ready else {
            bufferedEvents[conversationID, default: []].append(event)
            return
        }

        do {
            _ = try registration.pane.consume(event, in: registration.pane.conversationID)
            if registration.pane.liveStore.needsTimelineReload {
                registration.state = .waitingForRecovery
                if isDetached {
                    detachedPanesByConversationID[conversationID] = registration
                } else {
                    panesByConversationID[conversationID] = registration
                }
                recoveryMessages[conversationID] = "无法加载会话内容，请重试。"
                if !Self.isRunAccepted(event) {
                    bufferedEvents[conversationID, default: []].append(event)
                }
                record("Part delta offset mismatch for \(runID) in \(conversationID)")
            }
        } catch {
            registration.state = .waitingForRecovery
            if isDetached {
                detachedPanesByConversationID[conversationID] = registration
            } else {
                panesByConversationID[conversationID] = registration
            }
            recoveryMessages[conversationID] = "无法加载会话内容，请重试。"
            if !Self.isRunAccepted(event) {
                bufferedEvents[conversationID, default: []].append(event)
            }
            record("Timeline load failed for \(runID) in \(conversationID)")
        }
    }

    private func replayBufferedEvents(for conversationID: String) {
        guard let registration = panesByConversationID[conversationID],
              registration.state == .ready,
              var events = bufferedEvents.removeValue(forKey: conversationID) else { return }

        while !events.isEmpty {
            let event = events.removeFirst()
            if case .messagePartStarted(let runID, let messageID, let partID, let kind) = event,
               activeRunIDsByConversationID[conversationID]?.contains(runID) == true,
               registration.pane.liveStore.resumePersistedPart(
                   runID: runID,
                   messageID: messageID,
                   partID: partID,
                   kind: kind
               ) {
                continue
            }
            if isAlreadyReflected(event, in: registration.pane) {
                continue
            }
            do {
                _ = try registration.pane.consume(event, in: registration.pane.conversationID)
                if registration.pane.liveStore.needsTimelineReload {
                    markRecovery(for: conversationID, runID: Self.runID(for: event))
                    if !Self.isRunAccepted(event) {
                        events.insert(event, at: 0)
                    }
                    events.append(contentsOf: bufferedEvents.removeValue(forKey: conversationID) ?? [])
                    bufferedEvents[conversationID] = events
                    return
                }
            } catch {
                markRecovery(for: conversationID, runID: Self.runID(for: event))
                if !Self.isRunAccepted(event) {
                    events.insert(event, at: 0)
                }
                events.append(contentsOf: bufferedEvents.removeValue(forKey: conversationID) ?? [])
                bufferedEvents[conversationID] = events
                return
            }
        }
    }

    private func isAlreadyReflected(_ event: AgentEvent, in pane: ConversationPaneController) -> Bool {
        let timeline = pane.liveStore.state.timeline
        switch event {
        case .runAccepted(let runID, _):
            return timeline.turns.contains { $0.runID == runID }
        case .messagePartStarted(let runID, _, let partID, let kind):
            guard kind == .text || kind == .reasoning else { return false }
            return hasPersistedPart(partID, in: runID, timeline: timeline)
        case .messagePartDelta:
            return false
        case .messagePartCompleted(let runID, let partID, _):
            return hasCompletedPersistedPart(partID, in: runID, timeline: timeline)
        case .approvalRequired(_, let toolCallID):
            return pane.liveStore.state.pendingToolApprovals.contains {
                $0.toolCallID == toolCallID
            }
        case .runStateChanged, .toolCallChanged, .runEnded:
            return false
        }
    }

    private func hasPersistedPart(
        _ partID: String,
        in runID: String,
        timeline: ConversationTimelineProjection
    ) -> Bool {
        timeline.turns.first(where: { $0.runID == runID })?.textSourcesByItemIndex.values
            .contains(where: { $0.partID == partID }) ?? false
    }

    private func hasCompletedPersistedPart(
        _ partID: String,
        in runID: String,
        timeline: ConversationTimelineProjection
    ) -> Bool {
        timeline.turns.first(where: { $0.runID == runID })?.textSourcesByItemIndex.values
            .contains(where: { $0.partID == partID && $0.isCompleted }) ?? false
    }

    private func markRecovery(for conversationID: String, runID: String) {
        guard var registration = panesByConversationID[conversationID] else { return }
        registration.state = .waitingForRecovery
        panesByConversationID[conversationID] = registration
        recoveryMessages[conversationID] = "无法加载会话内容，请重试。"
        record("Timeline load failed for \(runID) in \(conversationID)")
    }

    private func finishActiveRun(_ runID: String, in conversationID: String) {
        activeRunIDsByConversationID[conversationID]?.remove(runID)
        acceptedRunOrder.removeAll { $0 == runID }
        guard activeRunIDsByConversationID[conversationID]?.isEmpty != false else { return }

        activeRunIDsByConversationID.removeValue(forKey: conversationID)
        let releasedDetachedPane = detachedPanesByConversationID.removeValue(forKey: conversationID) != nil
        if releasedDetachedPane, panesByConversationID[conversationID] == nil {
            bufferedEvents.removeValue(forKey: conversationID)
            recoveryMessages.removeValue(forKey: conversationID)
        }
    }

    private func record(_ diagnostic: String) {
        diagnostics.append(diagnostic)
        if diagnostics.count > 64 {
            diagnostics.removeFirst(diagnostics.count - 64)
        }
    }

    private static func isRunAccepted(_ event: AgentEvent) -> Bool {
        if case .runAccepted = event { return true }
        return false
    }

    private static func runID(for event: AgentEvent) -> String {
        switch event {
        case .runAccepted(let runID, _),
             .runStateChanged(let runID, _),
             .messagePartStarted(let runID, _, _, _),
             .messagePartDelta(let runID, _, _, _),
             .messagePartCompleted(let runID, _, _),
             .toolCallChanged(let runID, _, _),
             .approvalRequired(let runID, _),
             .runEnded(let runID, _, _):
            return runID
        }
    }
}

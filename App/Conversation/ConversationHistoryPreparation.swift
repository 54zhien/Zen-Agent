import Foundation

struct PreparedConversationHistory: Sendable {
    let snapshot: ConversationHistorySnapshot
    let timeline: ConversationTimelineProjection
}

/// One worker at a time, including cancelled workers that have not finished yet.
/// Open, Return and reload use this owner so repeated navigation cannot pile up reads.
@MainActor
final class ConversationHistoryPreparation {
    enum Intent: Equatable { case navigation, maintenance }
    private struct Worker {
        let id: UUID
        let task: Task<PreparedConversationHistory, Error>
    }
    private var worker: Worker?
    private var requestID = UUID()
    private var cancellationGeneration = UUID()
    private var latestIntent: Intent?
    private var navigationRequests: Set<UUID> = []
    private var navigationWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var requested = 0
    private(set) var started = 0
    private(set) var finished = 0
    var inFlight: Int { worker == nil ? 0 : 1 }

    func cancel() {
        cancellationGeneration = UUID()
        latestIntent = nil
        requestID = UUID()
        worker?.task.cancel()
    }

    func prepare(id: String, store: PersistenceStore,
                 intent: Intent = .navigation) async throws -> PreparedConversationHistory {
        requested += 1
        let generation = cancellationGeneration
        if intent == .navigation {
            let navigation = UUID()
            navigationRequests.insert(navigation)
            defer {
                navigationRequests.remove(navigation)
                if navigationRequests.isEmpty {
                    let waiters = navigationWaiters
                    navigationWaiters.removeAll()
                    for waiter in waiters { waiter.resume() }
                }
            }
            return try await perform(id: id, store: store, intent: intent, generation: generation)
        }
        // A late Send acceptance on the outgoing Pane cannot replace the user's
        // Open. If navigation interrupts maintenance, its caller resumes afterward.
        while true {
            while !navigationRequests.isEmpty {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    navigationWaiters.append(continuation)
                }
            }
            try Task.checkCancellation()
            guard cancellationGeneration == generation else { throw CancellationError() }
            do {
                return try await perform(id: id, store: store, intent: intent, generation: generation)
            } catch is CancellationError {
                guard !Task.isCancelled, cancellationGeneration == generation,
                      latestIntent == .navigation else { throw CancellationError() }
            }
        }
    }

    private func perform(id: String, store: PersistenceStore, intent: Intent,
                         generation: UUID) async throws -> PreparedConversationHistory {
        try Task.checkCancellation()
        guard cancellationGeneration == generation else { throw CancellationError() }
        let request = UUID()
        requestID = request
        latestIntent = intent
        if let previous = worker {
            previous.task.cancel()
            _ = await previous.task.result
            finish(previous.id)
        }
        try Task.checkCancellation()
        guard requestID == request, cancellationGeneration == generation else { throw CancellationError() }
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let snapshot = try await store.conversationHistoryAsync(id: id)
            let timeline = try ConversationTimelineLoader.project(conversationID: id, snapshot: snapshot)
            return PreparedConversationHistory(snapshot: snapshot, timeline: timeline)
        }
        let workerID = UUID()
        worker = Worker(id: workerID, task: task)
        started += 1
        defer { finish(workerID) }
        let result = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        guard requestID == request, cancellationGeneration == generation else { throw CancellationError() }
        return result
    }

    private func finish(_ id: UUID) {
        guard worker?.id == id else { return }
        worker = nil
        finished += 1
    }
}

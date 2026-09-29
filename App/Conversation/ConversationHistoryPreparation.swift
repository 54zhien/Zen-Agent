import Foundation

struct PreparedConversationHistory: Sendable {
    let snapshot: ConversationHistorySnapshot
    let timeline: ConversationTimelineProjection
}

/// One worker at a time, including cancelled workers that have not finished yet.
/// Open, Return and reload use this owner so repeated navigation cannot pile up reads.
@MainActor
final class ConversationHistoryPreparation {
    private struct Worker {
        let id: UUID
        let task: Task<PreparedConversationHistory, Error>
    }
    private var worker: Worker?
    private var requestID = UUID()
    private(set) var started = 0
    private(set) var finished = 0
    var inFlight: Int { worker == nil ? 0 : 1 }

    func cancel() {
        requestID = UUID()
        worker?.task.cancel()
    }

    func prepare(id: String, store: PersistenceStore) async throws -> PreparedConversationHistory {
        let request = UUID()
        requestID = request
        if let previous = worker {
            previous.task.cancel()
            _ = await previous.task.result
            finish(previous.id)
        }
        try Task.checkCancellation()
        guard requestID == request else { throw CancellationError() }
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
        guard requestID == request else { throw CancellationError() }
        return result
    }

    private func finish(_ id: UUID) {
        guard worker?.id == id else { return }
        worker = nil
        finished += 1
    }
}

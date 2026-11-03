import EventKit
import Foundation

actor EventKitRemindersGateway: RemindersGateway {
    private struct PendingFetch {
        let identifier: Any
        let continuation: CheckedContinuation<[ReminderSummary], Error>
    }

    private let eventStore = EKEventStore()
    private var pendingFetches: [UUID: PendingFetch] = [:]

    func authorizationState() async -> ToolSystemPermissionState {
        Self.permissionState(for: EKEventStore.authorizationStatus(for: .reminder))
    }

    static func permissionState(for status: EKAuthorizationStatus) -> ToolSystemPermissionState {
        switch status {
        case .fullAccess:
            .authorized
        case .notDetermined:
            .notDetermined
        case .writeOnly:
            .notDetermined
        case .denied:
            .denied
        case .restricted:
            .restricted
        @unknown default:
            .unavailable
        }
    }

    func requestFullAccess() async throws {
        _ = try await eventStore.requestFullAccessToReminders()
    }

    func reminders(in query: RemindersQuery) async throws -> [ReminderSummary] {
        guard await authorizationState() == .authorized else {
            throw ToolSystemPermissionError.denied
        }
        try Task.checkCancellation()
        let requestID = UUID()
        let reminders = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[ReminderSummary], Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let predicate = eventStore.predicateForIncompleteReminders(
                    withDueDateStarting: query.startDate,
                    ending: query.endDate,
                    calendars: nil
                )
                let identifier = eventStore.fetchReminders(matching: predicate) { [weak self] reminders in
                    let summaries = reminders?.compactMap(Self.summary(for:)) ?? []
                    Task { await self?.completeFetch(requestID, with: summaries) }
                }
                pendingFetches[requestID] = PendingFetch(
                    identifier: identifier,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { await self.cancelFetch(requestID) }
        }
        try Task.checkCancellation()
        return reminders
    }

    private func completeFetch(_ requestID: UUID, with reminders: [ReminderSummary]) {
        guard let pending = pendingFetches.removeValue(forKey: requestID) else { return }
        pending.continuation.resume(returning: reminders)
    }

    private func cancelFetch(_ requestID: UUID) {
        guard let pending = pendingFetches.removeValue(forKey: requestID) else { return }
        eventStore.cancelFetchRequest(pending.identifier)
        pending.continuation.resume(throwing: CancellationError())
    }

    private static func summary(for reminder: EKReminder) -> ReminderSummary? {
        guard let due = reminder.dueDateComponents else { return nil }
        return ReminderSummary(
            title: reminder.title ?? "",
            listTitle: reminder.calendar.title ?? "",
            dueDate: ReminderDueDate(
                year: due.year,
                month: due.month,
                day: due.day,
                hour: due.hour,
                minute: due.minute,
                second: due.second,
                timeZone: due.timeZone,
                isFloating: due.timeZone == nil,
                isAllDay: due.hour == nil && due.minute == nil && due.second == nil
            )
        )
    }
}

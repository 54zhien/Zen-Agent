import EventKit
import Foundation

actor EventKitCalendarGateway: CalendarEventsGateway {
    private let eventStore = EKEventStore()

    func authorizationState() async -> ToolSystemPermissionState {
        Self.permissionState(for: EKEventStore.authorizationStatus(for: .event))
    }

    static func permissionState(for status: EKAuthorizationStatus) -> ToolSystemPermissionState {
        switch status {
        case .fullAccess:
            .authorized
        case .notDetermined:
            .notDetermined
        case .writeOnly:
            // Full access is still requestable, but only after the existing explicit consent step.
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
        _ = try await eventStore.requestFullAccessToEvents()
    }

    func events(in query: CalendarEventQuery) async throws -> [CalendarEventSummary] {
        guard await authorizationState() == .authorized else {
            throw ToolSystemPermissionError.denied
        }
        try Task.checkCancellation()
        let predicate = eventStore.predicateForEvents(
            withStart: query.startDate,
            end: query.endDate,
            calendars: nil
        )
        return eventStore.events(matching: predicate).map { event in
            CalendarEventSummary(
                title: event.title ?? "",
                startDate: event.startDate,
                endDate: event.endDate,
                isAllDay: event.isAllDay,
                location: event.location
            )
        }
    }
}

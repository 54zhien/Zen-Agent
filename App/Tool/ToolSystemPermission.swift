import Foundation

/// OS availability is read from the capability owner, independently of Tool grants.
enum ToolSystemPermissionState: String, Sendable, Equatable {
    case notRequired, authorized, notDetermined, denied, restricted, unavailable
}

/// Only real capability owners opt in. Ordinary sandbox tools need no OS prompt.
protocol ToolSystemPermissionProviding: ToolExecutable {
    var systemPermissionDescription: String { get }
    func systemPermissionState(for intent: ToolExecutionIntent) async throws -> ToolSystemPermissionState
    func requestSystemPermission(for intent: ToolExecutionIntent) async throws
}

enum ToolSystemPermissionError: Error, Equatable {
    case unavailable
    case consentRequired(String)
}

extension ToolRuntime {
    // Compile-ready conservative RED boundary. The owner path is implemented
    // only after the native contracts demonstrate missing behavior.
    func resolveSystemPermission(toolCallID: String, displayedIntentBinding: String,
                                 consent: Bool) async throws {
        throw ToolSystemPermissionError.unavailable
    }
}

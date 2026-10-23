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

/// Explicit runtime choice; persistent policy remains a separate Settings concern.
enum ToolApprovalScope: Sendable { case once, conversation }

extension ToolRuntime {
    func approve(toolCallID: String, displayedIntentBinding: String? = nil,
                 scope: ToolApprovalScope) throws {
        switch scope {
        case .once: try approve(toolCallID: toolCallID, displayedIntentBinding: displayedIntentBinding)
        case .conversation: throw ToolSystemPermissionError.unavailable
        }
    }
}

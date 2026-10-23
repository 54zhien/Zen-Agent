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

/// Explicit runtime choice; persistent policy remains a separate Settings concern.
enum ToolApprovalScope: Sendable { case once, conversation }

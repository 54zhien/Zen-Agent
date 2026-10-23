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
    /// A read-only status query. nil means the capability needs a concrete call
    /// target; Settings must not invent a granted status or request permission.
    func systemPermissionStateForSettings() async throws -> ToolSystemPermissionState?
}

extension ToolSystemPermissionProviding {
    func systemPermissionStateForSettings() async throws -> ToolSystemPermissionState? { nil }
}

enum ToolSystemPermissionError: Error, Equatable {
    case unavailable
    case denied
    case consentRequired(String)
}

/// Explicit runtime choice; persistent policy remains a separate Settings concern.
enum ToolApprovalScope: Sendable { case once, conversation }

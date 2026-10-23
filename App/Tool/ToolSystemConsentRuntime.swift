import Foundation

/// Owns external OS interaction, while the existing policy transaction owns all
/// Tool authority. This owner never dispatches an executor or issues a grant.
struct ToolSystemConsentRuntime: Sendable {
    let store: PersistenceStore
    let registry: ToolRegistry
    let safetyCap: ToolPolicySafetyCap
    let owner = UUID().uuidString

    func preflight(call: ToolCallRecord, intent: ToolExecutionIntent,
                   executor: any ToolExecutable) async throws -> ToolCallRecord {
        guard let driver = executor as? any ToolSystemPermissionProviding else { return call }
        let status = try await read(driver, intent: intent)
        let binding = ToolIntentBinding.make(try requiredJSON(call))
        switch status {
        case .notRequired, .authorized: return call
        case .notDetermined:
            return try store.changeToolSystemConsent(id: call.id, expectedAttempt: call.attempt,
                intentBinding: binding, descriptor: executor.descriptor, safetyCap: safetyCap,
                command: .wait(driver.systemPermissionDescription))
        case .denied, .restricted, .unavailable:
            return try store.rejectToolSystemAccess(id: call.id, expectedAttempt: call.attempt,
                intentBinding: binding, status: status)
        }
    }

    func resolve(id: String, binding: String, consent: Bool,
                 revalidate: @Sendable () throws -> Bool) async throws {
        let (call, intent, executor) = try pending(id: id)
        guard ToolPolicyIdentity.equals(ToolIntentBinding.make(try requiredJSON(call)), binding) else {
            throw PersistenceError.invalidTransition("System decision is for a stale displayed intent")
        }
        guard let driver = executor as? any ToolSystemPermissionProviding else {
            _ = try store.rejectToolSystemAccess(id: id, expectedAttempt: call.attempt,
                intentBinding: binding, status: .unavailable)
            return
        }
        if !consent {
            _ = try change(call, binding: binding, descriptor: executor.descriptor, command: .decline)
            return
        }
        let status = try await read(driver, intent: intent)
        guard try revalidate() else { return }
        if status != .notDetermined {
            _ = try change(call, binding: binding, descriptor: executor.descriptor,
                command: .recover(owner: owner, status: status))
            return
        }
        let requestID = UUID().uuidString
        let claimed = try change(call, binding: binding, descriptor: executor.descriptor,
            command: .begin(owner: owner, requestID: requestID))
        guard claimed.state == .waitingForSystemPermissionConsent else { return }
        do {
            try Task.checkCancellation()
            try await driver.requestSystemPermission(for: intent)
            let currentStatus = try await read(driver, intent: intent)
            _ = try change(call, binding: binding, descriptor: executor.descriptor,
                command: .finish(owner: owner, requestID: requestID, status: currentStatus))
        } catch {
            // An interrupted request is not Tool authorization and cannot strand
            // a live owner in requesting forever. A concurrent Stop wins its CAS.
            _ = try change(call, binding: binding, descriptor: executor.descriptor,
                command: .finish(owner: owner, requestID: requestID, status: .unavailable))
            if error is CancellationError { throw CancellationError() }
            throw ToolSystemPermissionError.unavailable
        }
    }

    func recover(id: String, revalidate: @Sendable () throws -> Bool) async throws {
        let (call, intent, executor) = try pending(id: id)
        let status: ToolSystemPermissionState
        if let driver = executor as? any ToolSystemPermissionProviding {
            status = try await read(driver, intent: intent)
        } else { status = .unavailable }
        guard try revalidate() else { return }
        _ = try change(call, binding: ToolIntentBinding.make(try requiredJSON(call)),
            descriptor: executor.descriptor, command: .recover(owner: owner, status: status))
    }

    private func change(_ call: ToolCallRecord, binding: String, descriptor: ToolDescriptor,
                        command: ToolSystemConsentCommand) throws -> ToolCallRecord {
        try store.changeToolSystemConsent(id: call.id, expectedAttempt: call.attempt,
            intentBinding: binding, descriptor: descriptor, safetyCap: safetyCap, command: command)
    }

    private func pending(id: String) throws -> (ToolCallRecord, ToolExecutionIntent, any ToolExecutable) {
        guard let call = try store.toolCall(id: id), call.state == .waitingForSystemPermissionConsent else {
            throw ToolSystemPermissionError.consentRequired(id)
        }
        let intent = try ToolIntentCodec.decodeForDisplay(requiredJSON(call))
        guard let executor = registry.executor(id: intent.toolID) else { throw ToolSystemPermissionError.unavailable }
        try ToolIntentCodec.validate(intent, descriptor: executor.descriptor)
        try executor.validateDependencies(intent)
        return (call, intent, executor)
    }

    private func requiredJSON(_ call: ToolCallRecord) throws -> String {
        guard let json = call.executionIntent else { throw ToolRuntimeError.missingExecutionIntent(call.id) }
        return json
    }

    private func read(_ driver: any ToolSystemPermissionProviding,
                      intent: ToolExecutionIntent) async throws -> ToolSystemPermissionState {
        do { return try await driver.systemPermissionState(for: intent) }
        catch is CancellationError { throw CancellationError() }
        catch { return .unavailable }
    }
}

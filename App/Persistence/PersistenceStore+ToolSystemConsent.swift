import Foundation
import GRDB

enum ToolSystemConsentCommand: Sendable {
    case wait(String)
    case begin(owner: String, requestID: String)
    case finish(owner: String, requestID: String, status: ToolSystemPermissionState)
    case recover(owner: String, status: ToolSystemPermissionState)
    case decline
}

extension PersistenceStore {
    func toolSystemConsent(id: String) throws -> ToolSystemConsentRecord? {
        try database.read { try ToolSystemConsentRecord.fetchOne($0, key: id) }
    }

    /// Policy, original intent, interaction ownership and the next checkpoint
    /// commit together. The OS request itself deliberately happens afterward.
    func changeToolSystemConsent(id: String, expectedAttempt: Int, intentBinding: String,
        descriptor: ToolDescriptor, safetyCap: ToolPolicySafetyCap,
        command: ToolSystemConsentCommand, at now: Date = Date()) throws -> ToolCallRecord {
        try database.write { db in
            guard let call = try ToolCallRecord.fetchOne(db, key: id), call.attempt == expectedAttempt,
                  let json = call.executionIntent,
                  ToolPolicyIdentity.equals(ToolIntentBinding.make(json), intentBinding) else {
                throw PersistenceError.invalidTransition("System consent lost its original intent or attempt")
            }
            guard call.state == .prepared || call.state == .waitingForSystemPermissionConsent else { return call }
            let checked = try Self.authorizeToolCall(db, call: call, descriptor: descriptor, safetyCap: safetyCap,
                checkedIntentBinding: intentBinding, operation: .reconcile, at: now)
            guard checked.state == call.state else { return checked }
            var interaction = try ToolSystemConsentRecord.fetchOne(db, key: id)
            if let interaction {
                guard interaction.attempt == call.attempt,
                      ToolPolicyIdentity.equals(interaction.intentBinding, intentBinding) else {
                    return try Self.rejectAuthorizationCall(db, call: call, failure: .dependencyChanged, at: now)
                }
            }
            switch command {
            case .wait(let description):
                guard !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return try Self.rejectAuthorizationCall(db, call: call, failure: .dependencyUnavailable, at: now)
                }
                if call.state == .prepared {
                    interaction = ToolSystemConsentRecord(toolCallID: id, attempt: call.attempt,
                        intentBinding: intentBinding, capabilityDescription: description, phase: .waiting)
                    try interaction?.save(db)
                    return try Self.updateAuthorizationCall(db, call: call,
                        state: .waitingForSystemPermissionConsent, failure: nil, at: now)
                }
                return call
            case .begin(let owner, let requestID):
                guard call.state == .waitingForSystemPermissionConsent,
                      var value = interaction, value.phase == .waiting else {
                    throw PersistenceError.invalidTransition("System request is not waiting for an explicit decision")
                }
                value.phase = .requesting; value.requestID = requestID; value.requestOwner = owner
                try value.update(db)
                return call
            case .decline:
                guard call.state == .waitingForSystemPermissionConsent,
                      var value = interaction, value.phase == .waiting else {
                    throw PersistenceError.invalidTransition("System request cannot be declined in this phase")
                }
                value.phase = .declined; try value.update(db)
                return try Self.rejectAuthorizationCall(db, call: call, failure: .systemPermissionDenied, at: now)
            case .finish(let owner, let requestID, let status):
                guard call.state == .waitingForSystemPermissionConsent, var value = interaction,
                      value.phase == .requesting, value.requestOwner == owner, value.requestID == requestID else {
                    throw PersistenceError.invalidTransition("System callback lost request ownership")
                }
                value.phase = .completed; try value.update(db)
                return try Self.settleToolSystemAccess(db, call: call, status: status, at: now)
            case .recover(let owner, let status):
                if let value = interaction, value.phase == .requesting, value.requestOwner == owner { return call }
                if status == .notDetermined, var value = interaction {
                    value.phase = .waiting; value.requestID = nil; value.requestOwner = nil
                    try value.update(db)
                    return call
                }
                if var value = interaction { value.phase = .completed; try value.update(db) }
                return try Self.settleToolSystemAccess(db, call: call, status: status, at: now)
            }
        }
    }

    private static func settleToolSystemAccess(_ db: Database, call: ToolCallRecord,
        status: ToolSystemPermissionState, at now: Date) throws -> ToolCallRecord {
        switch status {
        case .authorized, .notRequired:
            return try updateAuthorizationCall(db, call: call, state: .prepared, failure: nil, at: now)
        case .notDetermined, .denied, .restricted:
            return try rejectAuthorizationCall(db, call: call, failure: .systemPermissionDenied, at: now)
        case .unavailable:
            return try rejectAuthorizationCall(db, call: call, failure: .dependencyUnavailable, at: now)
        }
    }

    func rejectToolSystemAccess(id: String, expectedAttempt: Int, intentBinding: String,
        status: ToolSystemPermissionState, at now: Date = Date()) throws -> ToolCallRecord {
        try database.write { db in
            guard let call = try ToolCallRecord.fetchOne(db, key: id), call.attempt == expectedAttempt,
                  let json = call.executionIntent, ToolPolicyIdentity.equals(ToolIntentBinding.make(json), intentBinding),
                  [.prepared, .waitingForSystemPermissionConsent].contains(call.state) else {
                throw PersistenceError.invalidTransition("System preflight lost its original pending call")
            }
            return try Self.settleToolSystemAccess(db, call: call, status: status, at: now)
        }
    }
}

import Foundation

#if canImport(UIKit)
import UIKit
#endif

struct DeviceInfoSnapshot: Sendable, Equatable {
    var osFamily: String
    var osVersion: String
    var deviceIdiom: String
    var genericModelClass: String
}

struct DeviceInfoTool: ToolExecutable {
    static let toolID = "device_info"

    let descriptor: ToolDescriptor
    private let snapshot: DeviceInfoSnapshot

    init(snapshot: DeviceInfoSnapshot) {
        self.snapshot = snapshot
        self.descriptor = ToolDescriptor(
            id: Self.toolID,
            displayName: "Device Info",
            description: "Returns a privacy-bounded device and operating-system summary.",
            inputSchema: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
            ]),
            revision: "1",
            sideEffect: .none,
            approvalRequirement: .notRequired
        )
    }

    init() {
        #if canImport(UIKit)
        let device = UIDevice.current
        let idiom: String
        switch device.userInterfaceIdiom {
        case .phone:
            idiom = "phone"
        case .pad:
            idiom = "tablet"
        case .tv:
            idiom = "tv"
        case .carPlay:
            idiom = "carPlay"
        case .mac:
            idiom = "desktop"
        default:
            idiom = "unknown"
        }

        self.init(
            snapshot: DeviceInfoSnapshot(
                osFamily: device.systemName,
                osVersion: device.systemVersion,
                deviceIdiom: idiom,
                genericModelClass: device.model
            )
        )
        #else
        self.init(
            snapshot: DeviceInfoSnapshot(
                osFamily: "Unknown",
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                deviceIdiom: "unknown",
                genericModelClass: "Unknown"
            )
        )
        #endif
    }

    func prepare(
        callID: String,
        argumentsJSON: String
    ) throws -> ToolExecutionIntent {
        _ = callID
        try ToolArgumentJSON.requireEmptyObject(argumentsJSON)

        return ToolExecutionIntent(
            formatVersion: ToolExecutionIntent.currentFormatVersion,
            toolID: descriptor.id,
            descriptorRevision: descriptor.revision,
            normalizedArgumentsJSON: "{}",
            targetIdentity: nil,
            destinationIdentity: nil
        )
    }

    func execute(
        _ intent: ToolExecutionIntent,
        idempotencyKey: String
    ) async throws -> ToolExecutionResult {
        _ = idempotencyKey
        guard
            intent.formatVersion == ToolExecutionIntent.currentFormatVersion,
            intent.toolID == descriptor.id,
            intent.descriptorRevision == descriptor.revision,
            intent.normalizedArgumentsJSON == "{}",
            intent.targetIdentity == nil,
            intent.destinationIdentity == nil
        else {
            throw ToolExecutionError.invalidIntent
        }

        let object: [String: String] = [
            "osFamily": snapshot.osFamily,
            "osVersion": snapshot.osVersion,
            "deviceIdiom": snapshot.deviceIdiom,
            "genericModelClass": snapshot.genericModelClass,
        ]
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ToolExecutionError.invalidArguments
        }

        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        guard let content = String(data: data, encoding: .utf8) else {
            throw ToolExecutionError.invalidArguments
        }
        return ToolExecutionResult(content: content)
    }
}

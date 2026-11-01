import Darwin
import Foundation
import UIKit
import XCTest

@testable import ZenAgent

final class Stage10MeasurementReportTests: XCTestCase {
    @MainActor
    func testAttachLatestParentChildMeasurement() async throws {
        let supportDirectory = try XCTUnwrap(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )
        let databaseURL = supportDirectory.appending(path: "ZenAgent.sqlite")
        let store = PersistenceStore(database: try ZenDatabase.open(at: databaseURL.path))
        let capture = await Stage10ManualMeasurementRecorder.shared.capture()

        guard let startedAt = capture.startedAt else {
            XCTFail("Launch ZenAgentManualMeasurement on the device, run the fixed dual-Child scenario, then attach its report.")
            return
        }

        let info = Bundle.main.infoDictionary ?? [:]
        let device = UIDevice.current
        #if targetEnvironment(simulator)
        let deviceEnvironment = "simulator"
        #else
        let deviceEnvironment = "physical"
        #endif
        let context = Stage10ManualMeasurementContext(
            startedAt: startedAt,
            scenario: "manual-fixed-dual-child-probe",
            deviceHardwareModel: hardwareModelIdentifier(),
            deviceModelClass: device.model,
            deviceEnvironment: deviceEnvironment,
            operatingSystemName: device.systemName,
            operatingSystemVersion: device.systemVersion,
            appVersion: info["CFBundleShortVersionString"] as? String,
            appBuild: info["CFBundleVersion"] as? String,
            sourceCommit: capture.sourceCommit,
            providerHTTP429Responses: capture.providerHTTP429Responses
        )

        guard let json = try store.latestParentChildMeasurementJSON(context: context) else {
            XCTFail("Run a Parent with the manual dual-Child snapshot after launching this scheme, then run the report test.")
            return
        }

        let attachment = XCTAttachment(data: json, uniformTypeIdentifier: "public.json")
        attachment.name = "Stage 10 Parent Child measurement"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func hardwareModelIdentifier() -> String? {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0 else { return nil }
        var machine = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &machine, &size, nil, 0) == 0 else { return nil }
        let identifier = String(cString: machine)
        return identifier.isEmpty ? nil : identifier
    }

}

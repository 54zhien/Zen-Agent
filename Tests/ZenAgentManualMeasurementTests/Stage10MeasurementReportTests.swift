import Foundation
import XCTest

@testable import ZenAgent

final class Stage10MeasurementReportTests: XCTestCase {
    func testAttachLatestParentChildMeasurement() throws {
        let supportDirectory = try XCTUnwrap(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )
        let databaseURL = supportDirectory.appending(path: "ZenAgent.sqlite")
        let store = PersistenceStore(database: try ZenDatabase.open(at: databaseURL.path))

        guard let json = try store.latestParentChildMeasurementJSON() else {
            XCTFail("Run a real Parent with at least one Child in Zen on this iPhone, then run this measurement scheme again.")
            return
        }

        let attachment = XCTAttachment(data: json, uniformTypeIdentifier: "public.json")
        attachment.name = "Stage 10 Parent Child measurement"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

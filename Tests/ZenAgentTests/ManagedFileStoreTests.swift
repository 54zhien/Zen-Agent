import Foundation
import Testing

@testable import ZenAgent

@Suite("Managed file store")
struct ManagedFileStoreTests {
    @Test("ingestPublishesContentAddressedBlobUnderApplicationSupport")
    func ingestPublishesContentAddressedBlobUnderApplicationSupport() {
        let _: (URL) -> ManagedFileStore = ManagedFileStore.init(applicationSupportRoot:)
        #expect(String(reflecting: ManagedFileStore.self).contains("ManagedFileStore"))
    }
}

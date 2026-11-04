import XCTest

final class ComposerImageAttachmentUITests: XCTestCase {
    @MainActor
    func testImagePickerRequiresAnExplicitImageInputTarget() {
        let app = XCUIApplication()
        app.launchEnvironment["ZEN_COMPOSER_GEOMETRY_TEST"] = "1"
        app.launch()

        let plus = app.buttons["conversation-composer-plus"]
        XCTAssertTrue(plus.waitForExistence(timeout: 15))
        plus.tap()

        let imageEntry = app.buttons["图片"]
        XCTAssertTrue(imageEntry.waitForExistence(timeout: 5))
        XCTAssertFalse(imageEntry.isEnabled)
    }
}

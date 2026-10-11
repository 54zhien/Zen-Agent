import XCTest
import UIKit

final class SidebarAppearanceUITests: XCTestCase {
    @MainActor
    func testLightAppearanceSidebarRailUsesLightSurface() {
        let app = launchLightAppearance()
        app.openWorkspaceSidebar()

        let rail = app.descendants(matching: .any)["sidebar-rail"]
        XCTAssertTrue(rail.waitForExistence(timeout: 10))
        let capture = app.screenshot()
        attach(capture, named: "Light sidebar with exposed rail")

        let point = CGPoint(x: rail.frame.midX, y: rail.frame.midY)
        guard let luminance = sampledLuminance(capture, appFrame: app.frame, at: point) else {
            XCTFail("Could not sample the exposed rail inside its measured frame: \(rail.frame)")
            return
        }
        print("SIDEBAR_APPEARANCE rail=\(rail.frame);sample=\(point);luminance=\(luminance)")
        XCTAssertGreaterThan(luminance, 0.6,
                             "The exposed Sidebar should read as a light surface in Light appearance")
    }

    @MainActor
    func testSplitLowerPaneKeepsLightBottomCornersAboveVisibleKeyboard() {
        let app = launchLightAppearance()
        app.openWorkspaceSidebar()
        app.buttons["split-entry"].tap()
        app.buttons["split-open-top"].tap()
        let history = app.buttons["split-history-preview-ui-10"]
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        history.tap()

        let upperPane = app.scrollViews.matching(identifier: "conversation-pane-preview-ui-10").firstMatch
        let lowerPane = app.scrollViews.matching(identifier: "conversation-pane-preview-ui-11").firstMatch
        XCTAssertTrue(upperPane.waitForExistence(timeout: 10))
        XCTAssertTrue(lowerPane.waitForExistence(timeout: 10))
        XCTAssertLessThan(upperPane.frame.midY, lowerPane.frame.midY,
                          "The fixture should keep the selected conversation in the lower pane")

        app.activateWorkspacePane("preview-ui-11")
        let editor = app.textViews["conversation-composer-input"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10))

        let divider = app.descendants(matching: .any)["split-divider"]
        XCTAssertTrue(divider.exists)
        let capture = app.screenshot()
        attach(capture, named: "Light split with lower Composer keyboard")

        guard let lowerFrame = splitViewportFrame(app, slot: "bottom") else {
            XCTFail("The existing split viewport probe must expose the rendered lower-pane frame")
            return
        }
        XCTAssertTrue(app.frame.contains(lowerFrame),
                      "The measured lower-pane frame must map to the captured app screenshot: \(lowerFrame)")

        let inset: CGFloat = 1.5
        let leftCorner = CGPoint(x: lowerFrame.minX + inset, y: lowerFrame.maxY - inset)
        let rightCorner = CGPoint(x: lowerFrame.maxX - inset, y: lowerFrame.maxY - inset)
        XCTAssertLessThan(leftCorner.y, keyboard.frame.minY,
                          "The lower-pane corner sample must be above the visible keyboard")
        XCTAssertLessThan(rightCorner.y, keyboard.frame.minY,
                          "The lower-pane corner sample must be above the visible keyboard")

        guard let leftLuminance = sampledLuminance(capture, appFrame: app.frame, at: leftCorner),
              let rightLuminance = sampledLuminance(capture, appFrame: app.frame, at: rightCorner) else {
            XCTFail("Could not sample both lower-pane corners from their measured frame: \(lowerFrame)")
            return
        }

        let dividerPoint = CGPoint(x: lowerFrame.minX + 8, y: divider.frame.midY)
        guard let dividerLuminance = sampledLuminance(capture, appFrame: app.frame, at: dividerPoint) else {
            XCTFail("Could not sample the divider within its measured frame: \(divider.frame)")
            return
        }
        print("SPLIT_APPEARANCE lower=\(lowerFrame);keyboard=\(keyboard.frame);left=\(leftLuminance);right=\(rightLuminance);divider=\(divider.frame),sample=\(dividerPoint),luminance=\(dividerLuminance)")

        XCTAssertGreaterThan(leftLuminance, 0.6,
                             "The lower pane's bottom-left corner should not expose a black mask")
        XCTAssertGreaterThan(rightLuminance, 0.6,
                             "The lower pane's bottom-right corner should not expose a black mask")
        XCTAssertLessThan(dividerLuminance, 0.2,
                          "The split divider should remain visibly dark between the light panes")
    }

    @MainActor
    private func launchLightAppearance() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleInterfaceStyle", "Light"]
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launch()
        XCTAssertTrue(app.textViews["conversation-composer-input"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor
    private func attach(_ capture: XCUIScreenshot, named name: String) {
        XCTContext.runActivity(named: name) { activity in
            let attachment = XCTAttachment(screenshot: capture)
            attachment.name = name
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
    }

    @MainActor
    private func splitViewportFrame(_ app: XCUIApplication, slot: String) -> CGRect? {
        let probe = app.descendants(matching: .any)["split-viewport-probe"]
        guard let value = probe.value as? String,
              let marker = value.range(of: "\(slot)=(") else { return nil }
        let suffix = value[marker.upperBound...]
        guard let end = suffix.firstIndex(of: ")") else { return nil }
        let components = suffix[..<end].split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard components.count == 4 else { return nil }
        return CGRect(x: components[0], y: components[1], width: components[2], height: components[3])
    }

    private func sampledLuminance(_ capture: XCUIScreenshot,
                                 appFrame: CGRect,
                                 at point: CGPoint) -> Double? {
        let image = capture.image
        guard let source = image.cgImage,
              appFrame.width > 0, appFrame.height > 0,
              appFrame.contains(point) else { return nil }

        let scaleX = CGFloat(source.width) / appFrame.width
        let scaleY = CGFloat(source.height) / appFrame.height
        let pixelX = Int(((point.x - appFrame.minX) * scaleX).rounded(.down))
        let pixelY = Int(((point.y - appFrame.minY) * scaleY).rounded(.down))
        let cropRect = CGRect(x: pixelX - 1, y: pixelY - 1, width: 3, height: 3)
        guard let patch = source.cropping(to: cropRect) else { return nil }

        let width = patch.width
        let height = patch.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let rendered = rgba.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: bitmapInfo) else { return false }
            context.interpolationQuality = .none
            context.draw(patch, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }

        var total = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let red = Double(rgba[index]) / 255
                let green = Double(rgba[index + 1]) / 255
                let blue = Double(rgba[index + 2]) / 255
                total += 0.2126 * red + 0.7152 * green + 0.0722 * blue
            }
        }
        return total / 9
    }
}

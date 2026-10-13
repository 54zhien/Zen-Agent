import XCTest
import UIKit

final class SidebarAppearanceUITests: XCTestCase {
    @MainActor
    func testCustomTopReusesIdlePixelsAndUpdatesDuringNativeScrolling() {
        let app = launchLightAppearance()
        let native = app.descendants(matching: .any)["surface-native-interaction-probe"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let value = native.value as? String ?? ""
            return (self.metric("topEdgeCaptures", from: native) ?? 0) > 0
                && value.contains("topEdgePending=false;") && value.contains("topEdgeDirty=false;")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        let idleCount = metric("topEdgeCaptures", from: native)
        let unexpected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.metric("topEdgeCaptures", from: native) != idleCount
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [unexpected], timeout: 1), .timedOut,
                       "An unchanged visible page must reuse its captured strip")
        let duringScroll = metric("topEdgeScrollCaptures", from: native) ?? 0
        guard let beforeOffset = nativeScrollOffset(from: native) else {
            XCTFail("The native timeline must expose its actual scroll offset")
            return
        }
        let timeline = app.scrollViews.matching(identifier: "conversation-pane-preview-ui-11").firstMatch
        XCTAssertTrue(timeline.isHittable)
        timeline.swipeDown(velocity: .slow)
        let progressed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (self.metric("topEdgeScrollCaptures", from: native) ?? 0) > duringScroll
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [progressed], timeout: 10), .completed,
                       "At least one result must commit while the native scroll phase is active")
        guard let afterOffset = nativeScrollOffset(from: native) else {
            XCTFail("The retained native timeline offset must remain measurable")
            return
        }
        XCTAssertNotEqual(afterOffset.y, beforeOffset.y, "The real timeline must move during the gesture")
        print("TOP_EDGE_NATIVE_SCROLL \(native.value ?? "missing")")
        attach(app.screenshot(), named: "Custom top after real native scrolling")
    }

    @MainActor
    func testDarkProgressiveTopAndActuallyExpandedSidebar() {
        let app = launchLightAppearance()
        app.openWorkspaceSidebar()
        app.buttons["sidebar-settings"].tap()
        let page = app.descendants(matching: .any)["settings-page"]
        XCTAssertTrue(page.waitForExistence(timeout: 10))
        let appearance = app.buttons["外观"].firstMatch
        if !appearance.isHittable { page.swipeUp() }
        XCTAssertTrue(appearance.waitForExistence(timeout: 10))
        appearance.tap()
        let picker = app.buttons["settings-appearance-picker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.tap()
        app.buttons["深色"].tap()
        XCTAssertTrue("\(picker.label) \(picker.value ?? "")".contains("深色"))
        app.buttons["settings-close"].tap()
        XCTAssertTrue(page.wait(for: \.exists, toEqual: false, timeout: 10))
        let native = app.descendants(matching: .any)["surface-native-interaction-probe"]
        let rendered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (self.metric("topEdgeCaptures", from: native) ?? 0) > 0
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [rendered], timeout: 10), .completed)
        attach(app.screenshot(), named: "Dark full page progressive top")
        app.openWorkspaceSidebar()
        XCTAssertTrue(app.buttons["sidebar-settings"].isHittable)
        let capture = app.screenshot()
        attach(capture, named: "Dark actually expanded Sidebar and continuous corners")
        let rail = app.descendants(matching: .any)["sidebar-rail"]
        guard let luminance = sampledLuminance(capture, appFrame: app.frame,
            at: CGPoint(x: rail.frame.midX, y: rail.frame.midY)) else {
            XCTFail("The expanded dark Sidebar must have measurable pixels")
            return
        }
        XCTAssertLessThan(luminance, 0.2)
    }
    @MainActor
    func testSidebarEdgeWithTopSamplingDisabledControl() {
        let app = launchLightAppearance(captureDisabled: true)
        app.openWorkspaceSidebar()
        XCTAssertTrue(app.buttons["sidebar-settings"].exists)
    }

    @MainActor
    func testSidebarEdgeWithTimelineClippingControl() {
        let app = launchLightAppearance(timelineClipped: true)
        app.openWorkspaceSidebar()
        XCTAssertTrue(app.buttons["sidebar-settings"].exists)
    }

    @MainActor
    func testSidebarEdgeWithBothControls() {
        let app = launchLightAppearance(captureDisabled: true, timelineClipped: true)
        app.openWorkspaceSidebar()
        XCTAssertTrue(app.buttons["sidebar-settings"].exists)
    }
    @MainActor
    func testRestingControlsShareTheWindowCornerCenters() {
        let app = launchLightAppearance()
        let native = app.descendants(matching: .any)["surface-native-interaction-probe"]
        let composer = app.descendants(matching: .any)["composer-geometry-probe"]
        guard let radius = metric("windowCornerRadius", from: native),
              let frame = rect("surfaceRect", from: composer),
              let composerRadius = metric("corner", from: composer) else {
            XCTFail("Native window and Composer geometry must be available")
            return
        }
        XCTAssertGreaterThan(radius, 0)
        if let readable = rect("timelineVisibleFrame", from: native),
           let topEdge = rect("topEdgeFrame", from: native),
           let safeTop = metric("windowSafeTop", from: native) {
            XCTAssertEqual(readable.minY, app.frame.minY + safeTop, accuracy: 1,
                           "The status-area fade must preserve the existing readable top inset")
            XCTAssertEqual(topEdge.minY, app.frame.minY, accuracy: 1)
            XCTAssertEqual(topEdge.height, safeTop + 48, accuracy: 1,
                           "Progressive blur must extend below the status area and taper over actual content")
            XCTAssertEqual(topEdge.width, app.frame.width, accuracy: 1)
        } else {
            XCTFail("The native readable viewport must be measurable")
        }
        attach(app.screenshot(), named: "Resting Composer and Conversation scroll edge")
        print("CONCENTRIC resting=\(frame);composerRadius=\(composerRadius);windowRadius=\(radius)")
        XCTAssertEqual(frame.minX + composerRadius, app.frame.minX + radius, accuracy: 1)
        XCTAssertEqual(frame.maxY - composerRadius, app.frame.maxY - radius, accuracy: 1)

        app.openWorkspaceSidebar()
        let top = app.buttons["new-conversation-new"].frame
        let bottom = app.buttons["sidebar-settings"].frame
        attach(app.screenshot(), named: "Window corner alignment")
        print("CONCENTRIC top=\(top);bottom=\(bottom);window=\(app.frame);radius=\(radius)")
        XCTAssertEqual(top.width, 48, accuracy: 1)
        XCTAssertEqual(top.height, 48, accuracy: 1)
        XCTAssertEqual(top.midX, app.frame.minX + radius, accuracy: 1)
        XCTAssertEqual(top.midY, app.frame.minY + radius, accuracy: 1)
        XCTAssertEqual(bottom.midX, app.frame.minX + radius, accuracy: 1)
        XCTAssertEqual(bottom.midY, app.frame.maxY - radius, accuracy: 1)
        guard let sheet = rect("surfaceFrame", from: native) else {
            XCTFail("The translated native sheet must expose its frame")
            return
        }
        XCTAssertEqual(sheet.minX - top.maxX, top.minX - app.frame.minX, accuracy: 1)
    }

    @MainActor
    func testSingleSurfaceRemainsFullHeightWhenItsKeyboardOpens() {
        let app = launchLightAppearance()
        let native = app.descendants(matching: .any)["surface-native-interaction-probe"]
        guard let before = rect("hostFrame", from: native) else {
            XCTFail("The retained native Surface frame must be available")
            return
        }
        app.textViews["conversation-composer-input"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        guard let after = rect("hostFrame", from: native) else {
            XCTFail("The retained native Surface must remain mounted")
            return
        }
        let composer = app.descendants(matching: .any)["composer-geometry-probe"]
        attach(app.screenshot(), named: "Single Conversation with native keyboard")
        print("SINGLE_KEYBOARD before=\(before);after=\(after);composer=\(composer.value ?? "missing")")
        print("SINGLE_KEYBOARD_NATIVE \(native.value ?? "missing")")
        XCTAssertEqual(before.maxY, app.frame.maxY, accuracy: 1)
        XCTAssertEqual(after.maxY, before.maxY, accuracy: 1,
                       "The outer page must cover the whole window while its inner timeline and native Composer avoid the keyboard")
        XCTAssertEqual(after.minY, before.minY, accuracy: 1)
        XCTAssertEqual(after.height, before.height, accuracy: 1)
        XCTAssertEqual(after.minX, before.minX, accuracy: 1)
        XCTAssertEqual(after.width, before.width, accuracy: 1)
    }

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

        let upperPane = app.scrollViews.matching(identifier: "conversation-pane-preview-ui-11").firstMatch
        let lowerPane = app.scrollViews.matching(identifier: "conversation-pane-preview-ui-10").firstMatch
        XCTAssertTrue(upperPane.waitForExistence(timeout: 10))
        XCTAssertTrue(lowerPane.waitForExistence(timeout: 10))
        XCTAssertLessThan(upperPane.frame.midY, lowerPane.frame.midY,
                          "The fixture should keep the selected conversation in the lower pane")

        app.activateWorkspacePane("preview-ui-10")
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
    private func launchLightAppearance(captureDisabled: Bool = false, timelineClipped: Bool = false,
                                      dark: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleInterfaceStyle", dark ? "Dark" : "Light"]
        app.launchEnvironment["ZEN_PREVIEW_HANDOFF_UI_TEST"] = "1"
        app.launchEnvironment["ZEN_COMPOSER_GEOMETRY_TEST"] = "1"
        if captureDisabled { app.launchEnvironment["ZEN_TOP_CAPTURE_DISABLED_DIAGNOSTIC"] = "1" }
        if timelineClipped { app.launchEnvironment["ZEN_TIMELINE_CLIPPED_DIAGNOSTIC"] = "1" }
        app.launch()
        XCTAssertTrue(app.textViews["conversation-composer-input"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor
    private func metric(_ key: String, from element: XCUIElement) -> CGFloat? {
        guard let value = element.value as? String,
              let field = value.components(separatedBy: ";").first(where: { $0.hasPrefix(key + "=") }),
              let number = Double(field.dropFirst(key.count + 1)) else { return nil }
        return CGFloat(number)
    }

    @MainActor
    private func nativeScrollOffset(from element: XCUIElement) -> CGPoint? {
        guard let value = element.value as? String,
              let scroll = value.range(of: "nativeScroll="),
              let start = value[scroll.upperBound...].range(of: ";offset=("),
              let end = value[start.upperBound...].firstIndex(of: ")") else { return nil }
        let values = value[start.upperBound..<end].split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard values.count == 2 else { return nil }
        return CGPoint(x: values[0], y: values[1])
    }

    @MainActor
    private func rect(_ key: String, from element: XCUIElement) -> CGRect? {
        guard let value = element.value as? String,
              let start = value.range(of: key + "=("),
              let end = value[start.upperBound...].firstIndex(of: ")") else { return nil }
        let values = value[start.upperBound..<end].split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard values.count == 4 else { return nil }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
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

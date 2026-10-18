import SwiftUI
import UIKit
import Testing
@testable import ZenAgent

@Suite("Device feedback spatial behavior", .serialized)
@MainActor
struct DeviceFeedbackGeometryTests {
    @Test func leftBrowseKeepsOneHorizontalCenterline() throws {
        let size = CGSize(width: 390, height: 844)
        var previous: CGRect?
        for offset in [0.0, -0.25, -0.5, -0.75, -1] {
            let layout = try #require(AppSpaceBrowseGeometry.resolve(size: size, safeArea: .zero,
                historyIDs: ["a", "b", "c", "d"], current: .conversation("c"), offset: offset,
                minimumCardSize: CGSize(width: 220, height: 300)))
            let outgoing = try #require(layout.cards.first { $0.item == .conversation("c") })
            for card in layout.cards { #expect(abs(card.frame.midY - size.height / 2) < 0.001) }
            if let previous {
                #expect(outgoing.frame.midX < previous.midX)
                #expect(outgoing.frame.width < previous.width)
            }
            previous = outgoing.frame
        }
    }

    @Test func interactiveLiftDampsVerticalTravelWithoutCropping() throws {
        let host = ConversationSurfaceViewController(content: Text("Whole page"))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        let driver = SurfaceLiftController(); driver.bind(host)
        defer { driver.unbind(host) }
        #expect(driver.arm(SurfaceLiftEligibility()))
        #expect(host.surfaceView.transform == .identity)
        let verticalLimit = (host.view.bounds.height - host.view.safeAreaInsets.top
            - host.view.safeAreaInsets.bottom) * 0.12
        var previousTravel: CGFloat = 0
        for distance in [80.0, 140.0] {
            #expect(driver.drag(upwardDistance: distance, eligibility: SurfaceLiftEligibility()))
            #expect(abs(host.presentation.translation.width) < 0.001)
            let travel = -host.presentation.translation.height
            #expect(travel > previousTravel && travel < distance && travel < verticalLimit)
            previousTravel = travel
            #expect(host.presentation.clipFraction == CGSize(width: 1, height: 1))
        }
        _ = driver.end(cancelled: true, animated: false)
        #expect(host.surfaceView.transform == .identity)
    }

    @Test func interactiveLiftKeepsHorizontalTrackingAndDampsVerticalTravelWithoutChangingProgress() throws {
        let host = ConversationSurfaceViewController(content: Text("Two-axis retained page"))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()

        let driver = SurfaceLiftController()
        driver.bind(host)
        defer { driver.unbind(host) }
        let displacement = CGSize(width: 42, height: -120)
        let input = SurfaceLiftEligibility()
        #expect(driver.arm(input))
        #expect(driver.drag(displacement: displacement, eligibility: input))

        #expect(driver.state.phase == .lifting)
        #expect(abs(driver.state.progress - 108.0 / 168.0) < 0.000001)
        #expect(abs(host.presentation.translation.width - displacement.width) < 0.001)
        let verticalLimit = (host.view.bounds.height - host.view.safeAreaInsets.top
            - host.view.safeAreaInsets.bottom) * 0.12
        #expect(host.presentation.translation.height < 0)
        #expect(abs(host.presentation.translation.height) < min(abs(displacement.height), verticalLimit))
        #expect(host.presentation.clipFraction == CGSize(width: 1, height: 1))
        _ = driver.end(cancelled: true, animated: false)
        #expect(driver.state.phase == .full)
        #expect(host.surfaceView.transform == .identity)
    }

    @Test func nativeLiftAdmitsLeftRightAndDownwardTravelAndCancellationRestoresFull() throws {
        let host = ConversationSurfaceViewController(content: Text("Directional retained page"))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()

        let driver = SurfaceLiftController()
        driver.bind(host)
        defer { driver.unbind(host) }
        let input = SurfaceLiftEligibility()
        for displacement in [CGSize(width: -48, height: 0),
                             CGSize(width: 48, height: 0),
                             CGSize(width: 0, height: 48)] {
            #expect(driver.arm(input))
            #expect(driver.drag(displacement: displacement, eligibility: input))
            #expect(driver.state.phase == .lifting)
            #expect(driver.state.progress == 0)
            #expect(abs(host.presentation.translation.width - displacement.width) < 0.001)
            if displacement.height == 0 {
                #expect(host.presentation.translation.height == 0)
            } else {
                #expect(host.presentation.translation.height > 0)
                #expect(host.presentation.translation.height < displacement.height)
            }
            let travel = hypot(Double(displacement.width), Double(displacement.height))
            let visualProgress = SurfaceLiftState.presentationProgress(travel: travel)
            #expect(abs(host.presentation.scale - (1 - visualProgress * 0.34)) < 0.001)

            let settlement = try #require(driver.end(cancelled: true, animated: false))
            #expect(settlement.destination == .full)
            #expect(driver.state.phase == .full)
            #expect(host.presentation == .full)
            #expect(host.surfaceView.transform == .identity)
        }
    }

    @Test func splitSurfacesLeaveARealGutterOnBothAxes() throws {
        for axis in [SplitWorkspaceAxis.topBottom, .leftRight] {
            let layout = try #require(SplitWorkspaceGeometry(viewport: CGRect(x: 0, y: 0, width: 800, height: 900), ratio: 0.63, axis: axis))
            if axis == .topBottom {
                #expect(layout.top.maxY < layout.bottom.minY)
                #expect(layout.divider.minY == layout.top.maxY)
                #expect(layout.divider.maxY == layout.bottom.minY)
            } else {
                #expect(layout.top.maxX < layout.bottom.minX)
                #expect(layout.divider.minX == layout.top.maxX)
                #expect(layout.divider.maxX == layout.bottom.minX)
            }
        }
    }

    @Test func lightSpaceIsDarkerThanItsWhiteConversationCards() throws {
        let canvas = AppSpaceInkNativeView()
        canvas.configure(policy: .resolve(enabled: false, intensity: 0, offset: 0,
            reduceMotion: false, lowPower: false, thermal: .nominal, sceneActive: true), dark: false)
        let color = try #require(canvas.backgroundColor?.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        #expect(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        #expect(max(red, green, blue) < 0.65)
        #expect(alpha == 1)
    }
}

import SwiftUI
import Testing
@testable import ZenAgent

@Suite("Sidebar rail geometry and progress")
struct SidebarRailLayoutTests {
    @Test(arguments: [false, true])
    func railRevealsTheAreaOutsideTheMovingPageCorners(isRightToLeft: Bool) {
        let bounds = CGRect(x: 0, y: 0, width: 96, height: 874)
        let mask = SidebarRailRevealShape(pageSize: CGSize(width: 402, height: 874),
            radius: 62, roundsBottom: true, offset: 48, isRightToLeft: isRightToLeft)
        let path = mask.path(in: bounds)
        let cornerX: CGFloat = isRightToLeft ? 36 : 60
        let exposedX: CGFloat = isRightToLeft ? 76 : 20
        #expect(path.contains(CGPoint(x: cornerX, y: 2), eoFill: true))
        #expect(path.contains(CGPoint(x: cornerX, y: 872), eoFill: true))
        #expect(!path.contains(CGPoint(x: cornerX, y: 437), eoFill: true))
        #expect(path.contains(CGPoint(x: exposedX, y: 437), eoFill: true))
    }

    @Test
    func railDoesNotInventABottomCornerAtTheKeyboardEdge() {
        let bounds = CGRect(x: 0, y: 0, width: 96, height: 539)
        let single = SidebarRailRevealShape(pageSize: CGSize(width: 402, height: 874),
            radius: 62, roundsBottom: true, offset: 48, isRightToLeft: false)
        let split = SidebarRailRevealShape(pageSize: CGSize(width: 402, height: 539),
            radius: 62, roundsBottom: false, offset: 48, isRightToLeft: false)
        let behindPage = CGPoint(x: 60, y: 537)
        #expect(!single.path(in: bounds).contains(behindPage, eoFill: true))
        #expect(!split.path(in: bounds).contains(behindPage, eoFill: true))
    }

    @Test(arguments: [CGFloat(48), 62, 72])
    func controlsHaveEqualScreenAndSheetGaps(radius: CGFloat) {
        let layout = SidebarRailLayout(windowInsets: EdgeInsets(), cornerRadius: radius)
        let controlLeft = layout.leading + (SidebarRailLayout.contentWidth - SidebarRailLayout.controlSize) / 2
        let controlRight = controlLeft + SidebarRailLayout.controlSize
        #expect(abs(layout.width - controlRight - controlLeft) < 0.01)
        #expect(abs(controlLeft - 20) < 0.01)
        #expect(abs(layout.width - 96) < 0.01)
    }

    @Test
    func controlsStayBelowStatusAreaAndAboveBottomSafeArea() {
        let insets = EdgeInsets(top: 59, leading: 20, bottom: 34, trailing: 0)
        let layout = SidebarRailLayout(windowInsets: insets, cornerRadius: 48)

        #expect(layout.top == 71)
        #expect(layout.bottom == 50)

        let left = layout.leading + (SidebarRailLayout.contentWidth - SidebarRailLayout.controlSize) / 2
        let right = left + SidebarRailLayout.controlSize
        #expect(layout.leading == 20)
        #expect(abs((layout.width - right) - left) < 0.01)
        #expect(abs(left + SidebarRailLayout.controlSize / 2 - 52) < 0.01)

        let windowHeight: CGFloat = 844
        #expect(windowHeight - layout.bottom == windowHeight - insets.bottom - 16)
    }

    @Test(arguments: [CGFloat(48), 55, 62])
    func settingsSharesTheDisplayCornerCenter(radius: CGFloat) {
        let layout = SidebarRailLayout(windowInsets: EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0),
                                       cornerRadius: radius)
        let placement = layout.settingsPlacement(windowCornerRadius: radius)
        let columnLeading = layout.leading + (SidebarRailLayout.contentWidth - SidebarRailLayout.controlSize) / 2
        let center = CGPoint(x: columnLeading + placement.leadingShift + SidebarRailLayout.controlSize / 2,
                             y: placement.bottom + SidebarRailLayout.controlSize / 2)
        // Both distances measured from the bottom-leading display corner.
        #expect(abs(center.x - radius) < 0.01)
        #expect(abs(center.y - radius) < 0.01)
        let mirrored = layout.settingsPlacement(windowCornerRadius: radius, isRightToLeft: true)
        #expect(mirrored.leadingShift == -placement.leadingShift)
    }

    @Test
    func squareDisplaysKeepSettingsInTheRailColumn() {
        let layout = SidebarRailLayout(windowInsets: EdgeInsets(top: 20, leading: 0, bottom: 0, trailing: 0),
                                       cornerRadius: 0)
        let placement = layout.settingsPlacement(windowCornerRadius: 0)
        #expect(placement.leadingShift == 0)
        #expect(placement.bottom == layout.bottom)
    }

    @Test
    func railAndBackdropOpacityTrackSidebarProgressContinuously() {
        let samples: [Double] = [-1, 0, 0.25, 0.5, 0.75, 1, 2]
        let opacities = samples.map { SidebarProgressPresentation.opacity(forProgress: $0) }
        var previous = 0.25
        for opacity in opacities {
            #expect(opacity >= previous)
            #expect((0.25...1).contains(opacity))
            previous = opacity
        }
        #expect(opacities.first == 0.25)
        #expect(opacities.last == 1)
        #expect(SidebarProgressPresentation.opacity(forProgress: .nan) == 0.25)
        #expect(SidebarProgressPresentation.opacity(forProgress: .infinity) == 0.25)
        #expect(SidebarProgressPresentation.opacity(forProgress: 2) == 1)
    }
}

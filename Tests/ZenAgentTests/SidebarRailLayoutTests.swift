import SwiftUI
import Testing
@testable import ZenAgent

@Suite("Sidebar rail geometry and progress")
struct SidebarRailLayoutTests {
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

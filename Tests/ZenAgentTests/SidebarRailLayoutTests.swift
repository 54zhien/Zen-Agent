import SwiftUI
import Testing
@testable import ZenAgent

@Suite("Sidebar equal exterior spacing")
struct SidebarRailLayoutTests {
    @Test(arguments: [CGFloat(48), 62, 72])
    func controlsHaveEqualScreenAndSheetGaps(radius: CGFloat) {
        let layout = SidebarRailLayout(windowInsets: EdgeInsets(), cornerRadius: radius)
        let controlLeft = layout.leading + (SidebarRailLayout.contentWidth - 48) / 2
        let controlRight = controlLeft + 48
        #expect(abs(layout.width - controlRight - controlLeft) < 0.01)
        #expect(abs(controlLeft + 24 - radius) < 0.01)
    }
}

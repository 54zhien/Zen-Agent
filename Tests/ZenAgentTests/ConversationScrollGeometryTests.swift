import SwiftUI
import Testing
@testable import ZenAgent

@Suite("Timeline native scroll coordinates")
@MainActor
struct ConversationScrollGeometryTests {
    @Test func shortContentDoesNotAcquireAnInsetSizedScrollRange() {
        let raw = SwiftUI.ScrollGeometry(contentOffset: CGPoint(x: 0, y: -116),
            contentSize: CGSize(width: 402, height: 56),
            contentInsets: EdgeInsets(top: 116, leading: 0, bottom: 108, trailing: 0),
            containerSize: CGSize(width: 402, height: 153))
        let geometry = ConversationTimelineView.paneGeometry(from: raw)
        #expect(geometry.viewportHeight == 153)
        #expect(geometry.contentHeight == 56)
        #expect(geometry.offset == 0)
        #expect(max(0, geometry.contentHeight - geometry.viewportHeight) == geometry.offset)
        #expect(BottomDetector.isAtBottom(geometry: geometry, tolerance: 0))
    }

    @Test func actualNativeBottomClearsTheLogicalBottomRequest() {
        let raw = SwiftUI.ScrollGeometry(contentOffset: CGPoint(x: 0, y: 1679),
            contentSize: CGSize(width: 402, height: 2042),
            contentInsets: EdgeInsets(top: 116, leading: 0, bottom: 74, trailing: 0),
            containerSize: CGSize(width: 402, height: 247))
        let geometry = ConversationTimelineView.paneGeometry(from: raw)
        #expect(geometry.viewportHeight == 247)
        #expect(geometry.contentHeight == 2042)
        #expect(geometry.offset == 1795)
        #expect(geometry.distanceFromBottom == 0)
    }
}

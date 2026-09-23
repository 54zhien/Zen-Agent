import Foundation
import Testing

@testable import ZenAgent

@Suite("Composer presentation reducer")
struct ComposerPresentationReducerTests {
    @Test("compactTapEntersEditingWithoutIntermediateResting")
    func compactTapEntersEditingWithoutIntermediateResting() {
        let transition = ComposerPresentationReducer.reduce(
            current: .compact,
            event: .compactTapped,
            isComposing: false,
            collapseProgress: .fullyCollapsed,
            pendingExit: nil
        )

        #expect(transition.targetState == .editing)
        #expect(transition.targetState != .resting)
        #expect(transition.focusCommand == .requestFocus)
    }
}

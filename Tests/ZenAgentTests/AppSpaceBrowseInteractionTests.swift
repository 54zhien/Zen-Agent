import UIKit
import Testing
@testable import ZenAgent

@MainActor
private final class SampledBrowsePan: UIPanGestureRecognizer {
    var sampleState: UIGestureRecognizer.State = .possible
    var displacement: CGFloat = 0
    override var state: UIGestureRecognizer.State {
        get { sampleState }
        set { sampleState = newValue }
    }
    override func translation(in view: UIView?) -> CGPoint { CGPoint(x: displacement, y: 0) }
    override func velocity(in view: UIView?) -> CGPoint { .zero }
}

@Suite("Native Browse final sample", .serialized)
@MainActor
struct AppSpaceBrowseInteractionTests {
    @Test("release displacement is consumed even without a final changed callback")
    func releaseUsesFinalDisplacement() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.createEmptyConversation(id: "older", at: Date(timeIntervalSince1970: 1))
        try store.createEmptyConversation(id: "current", at: Date(timeIntervalSince1970: 2))
        let browse = AppSpaceBrowseController(reader: { try store.conversationBrowseWindow(id: $0) })
        let surface = SurfaceClipView()
        let coordinates = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        coordinates.addSubview(surface)
        let input = AppSpaceBrowseInteraction(surface: surface, coordinates: coordinates,
            controller: browse, canBrowse: { true }, render: { _ in true }, refreshAccessibility: {})
        defer { input.unbind() }
        browse.present(originID: "current")
        let travel = try #require(browse.layout()).travel
        let pan = SampledBrowsePan()
        let action = NSSelectorFromString("gestureChanged:")
        pan.sampleState = .began
        pan.displacement = travel * 0.02
        _ = input.perform(action, with: pan)
        #expect(browse.state.phase == .dragging)
        pan.sampleState = .ended
        pan.displacement = travel * 0.6
        _ = input.perform(action, with: pan)
        // Reduce Motion may finish synchronously; otherwise inspect the real
        // native animator's admitted destination without waiting on wall time.
        #expect((browse.state.pendingSettlement?.destination ?? browse.state.selected) == .conversation("older"))
    }
}

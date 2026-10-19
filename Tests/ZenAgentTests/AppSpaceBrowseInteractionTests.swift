import UIKit
import SwiftUI
import Testing
@testable import ZenAgent

@MainActor
private final class SampledBrowsePan: UIPanGestureRecognizer {
    var sampleState: UIGestureRecognizer.State = .possible
    var displacement: CGFloat = 0
    var releaseVelocity: CGFloat = 0
    override var state: UIGestureRecognizer.State {
        get { sampleState }
        set { sampleState = newValue }
    }
    override func translation(in view: UIView?) -> CGPoint { CGPoint(x: displacement, y: 0) }
    override func velocity(in view: UIView?) -> CGPoint { CGPoint(x: releaseVelocity, y: 0) }
}

@Suite("Native Browse final sample", .serialized)
@MainActor
struct AppSpaceBrowseInteractionTests {
    @Test("release displacement is consumed even without a final changed callback")
    func releaseUsesFinalDisplacement() throws {
        try checkRelease(lastSample: 0.02, release: 0.6, expectedID: "older")
        try checkRelease(lastSample: 0.6, release: 0.02, expectedID: "current")
    }

    private func checkRelease(lastSample: CGFloat, release: CGFloat, expectedID: String) throws {
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
        pan.displacement = travel * lastSample
        _ = input.perform(action, with: pan)
        #expect(browse.state.phase == .dragging)
        pan.sampleState = .ended
        pan.displacement = travel * release
        _ = input.perform(action, with: pan)
        for _ in 0..<480 where input.isAnimating { input.advance(deltaTime: 1.0 / 120) }
        #expect(browse.state.selected == .conversation(expectedID))
        #expect(browse.state.phase == .idle)
    }

    @Test func aFlickCanBeCaughtInPlaceAndContinueThroughBoundedHistoryWindows() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        for index in 0..<12 {
            try store.createEmptyConversation(id: "coast-\(index)", at: Date(timeIntervalSince1970: Double(index)))
        }
        let browse = AppSpaceBrowseController(reader: { try store.conversationBrowseWindow(id: $0) })
        let host = ConversationSurfaceViewController(content: Text("retained page"))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        let lift = SurfaceLiftController()
        lift.bind(host)
        #expect(lift.arm(SurfaceLiftEligibility()))
        #expect(lift.drag(upwardDistance: 220, eligibility: SurfaceLiftEligibility()))
        _ = lift.end(animated: false)
        host.bindBrowse(browse)
        browse.present(originID: "coast-11")
        defer { host.unbindBrowse(); lift.unbind(host); window.isHidden = true; window.rootViewController = nil }
        let input = try #require(host.browseInteraction)
        let travel = try #require(browse.layout()).travel
        let pan = SampledBrowsePan()
        let action = NSSelectorFromString("gestureChanged:")
        pan.sampleState = .began
        _ = input.perform(action, with: pan)
        pan.sampleState = .ended
        pan.displacement = travel * 0.4
        pan.releaseVelocity = travel * 12
        _ = input.perform(action, with: pan)
        if input.isAnimating {
            input.advance(deltaTime: 0.025)
            let caught = host.presentation
            #expect(browse.state.offset > 0.4)
            pan.sampleState = .began
            pan.displacement = 0
            _ = input.perform(action, with: pan)
            #expect(!input.isAnimating && host.presentation == caught)
            pan.sampleState = .ended
            _ = input.perform(action, with: pan)
        }
        for _ in 0..<480 where input.isAnimating {
            input.advance(deltaTime: 1.0 / 120)
            #expect(browse.summaries.count <= 5)
            #expect(host.surfaceView.alpha == 1)
        }
        #expect(!input.isAnimating && browse.state.phase == .idle && browse.state.offset == 0)
        #expect(browse.state.selected != .conversation("coast-11"))
        #expect(browse.state.selected != .conversation("coast-10"))
    }
}

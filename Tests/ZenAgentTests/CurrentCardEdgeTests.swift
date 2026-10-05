import SwiftUI
import UIKit
import Testing

@testable import ZenAgent

@Suite("Current Card visible edge", .serialized)
@MainActor
struct CurrentCardEdgeTests {
    @Test("crop settlement cancellation clears the sole edge animation and Full hides it")
    func cropReplacementCancelsPresentationWork() throws {
        let view = SurfaceClipView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        view.layer.cornerRadius = 20
        view.visibleRect = CGRect(x: 40, y: 80, width: 320, height: 640)
        view.setCurrentEdgeVisible(true)
        let edge = try #require(view.layer.sublayers?.first { $0.name == "zen-current-card-edge" } as? CAShapeLayer)
        let changed = CGRect(x: 60, y: 160, width: 280, height: 480)
        UIView.animate(withDuration: 0.28) { view.visibleRect = changed }
        #expect(edge.animationKeys()?.count == 1)
        UIView.performWithoutAnimation { view.visibleRect = changed }
        #expect((edge.animationKeys() ?? []).isEmpty)
        #expect(abs(try #require(edge.path).boundingBoxOfPath.minX - changed.minX) <= 1)
        for _ in 0..<20 {
            view.setCurrentEdgeVisible(false)
            #expect(!view.currentEdgeVisible)
            view.setCurrentEdgeVisible(true)
            #expect(view.currentEdgeVisible)
        }
        #expect(view.layer.sublayers?.filter { $0.name == "zen-current-card-edge" }.count == 1)
        view.layer.cornerRadius = 0
        view.visibleRect = nil
        #expect(!view.currentEdgeVisible)
        #expect((edge.animationKeys() ?? []).isEmpty)
    }

    @Test("the Current edge follows its visible crop without accumulating layers")
    func edgeFitsTheCropAndDisappearsInFull() throws {
        let host = ConversationSurfaceViewController(content: Text("native edge fixture"))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        var pose = SurfaceGeometry.Pose(scale: 0.5, translation: .zero, cornerRadius: 20)
        pose.clipFraction = CGSize(width: 0.8, height: 0.7)
        for _ in 0..<12 {
            #expect(host.apply(.init(to: pose, progress: 1)))
            host.setLiftInteraction(.card, returnAction: { true })
        }
        let edges = (host.surfaceView.layer.sublayers ?? []).filter { $0.name == "zen-current-card-edge" }
        #expect(edges.count == 1)
        let edge = try #require(edges.first as? CAShapeLayer)
        let path = try #require(edge.path)
        let visible = try #require(host.surfaceView.visibleRect)
        let bounds = path.boundingBoxOfPath
        #expect(abs(bounds.minX - visible.minX) <= 1)
        #expect(abs(bounds.maxX - visible.maxX) <= 1)
        #expect(abs(bounds.minY - visible.minY) <= 1)
        #expect(abs(bounds.maxY - visible.maxY) <= 1)
        #expect(!edge.isHidden && edge.lineWidth > 0 && edge.lineWidth <= 1)
        #expect(edge.fillColor == nil || edge.fillColor?.alpha == 0)

        #expect(host.apply(.full))
        host.setLiftInteraction(.full, returnAction: { true })
        #expect(edge.isHidden || edge.opacity == 0)
        #expect((host.surfaceView.layer.sublayers ?? []).filter {
            $0.name == "zen-current-card-edge" && !$0.isHidden && $0.opacity > 0
        }.isEmpty)
    }
}
